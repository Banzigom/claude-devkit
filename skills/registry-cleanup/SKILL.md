---
name: registry-cleanup
description: コンテナレジストリの古い未使用イメージを、クラスタで使用中のものを保護しながら削除する。「レジストリ掃除」「イメージ掃除」「古いイメージ削除」「registry-cleanup」と言われた時に使用してください。
argument-hint: '[cutoff日付 YYYY-MM-DD]'
allowed-tools: Bash(bash *), Bash(kubectl get:*), Bash(gcloud artifacts docker images list:*), Bash(aws ecr describe-images:*), Bash(az acr repository show-tags:*), Bash(jq *), Bash(gh *), Read, AskUserQuestion
---

# registry-cleanup — 未使用イメージの削除

🔴 **削除は不可逆。「使用中のものを保護できていること」を確定させてから削除する（fail-closed）。**

## 対象・除外

- **対象**: `infra.registry` 配下の、cutoff 日以前に作られた**非保護**の digest
- **除外（保護）**: 稼働中のワークロードが参照している image / cutoff 以降のもの / 明示的な保護タグ

## Phase 0: 前提確認

```bash
DEVKIT_ENV=$(bash "$(git rev-parse --show-toplevel)/.claude/devkit/config.sh") || exit 1
eval "$DEVKIT_ENV"
[ -n "$DEVKIT_INFRA_REGISTRY" ] || { echo "infra.registry が未設定"; exit 1; }
```

認証と、対象レジストリへの一覧・削除権限を確認する。

## Phase 1: cutoff 日の確定

引数が無ければユーザーに確認する。**ISO 形式（`YYYY-MM-DD`）で検証してから変数に入れる。**

🔴 **日付の妥当性チェックを飛ばさない。** 空文字や不正な値がそのまま比較に使われると、**保護判定が壊れて全件が削除候補になる。**

## Phase 2: 使用中 image の収集（fail-closed）

🔴 **ここが最重要。収集に 1 件でも失敗したら削除へ進まない。**

```bash
# 全クラスタ・全 namespace のワークロードから image を集める
kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}'
kubectl get cronjob -A -o jsonpath='{range .items[*]}{.spec.jobTemplate.spec.template.spec.containers[*].image}{"\n"}{end}'
```

- **Pod だけでなく Deployment / CronJob / Job の spec も見る**（起動していないワークロードの image も保護対象）
- **複数クラスタ・複数プロジェクトがあるなら全部を回る。** 1 つでも取得に失敗したら**中断する**（取りこぼした image を消してしまう）
- 収集件数を出力し、**0 件なら異常として中断する**

## Phase 3: 保護 digest 集合の構築

タグ参照を digest に解決して集合を作る。**タグと digest を混ぜて比較しない**（同じ image が別表現で保護漏れする）。

## Phase 4: 削除候補の作成

`cutoff 以前` かつ `保護集合に無い` digest を候補にする。**候補件数と保護件数の両方を出す。**

## Phase 5: 削除直前の再収集（レース対策）

🔴 **候補作成から削除までの間にデプロイが走ると、たった今使われ始めた image を消す。** 削除の直前に保護集合を取り直し、候補から除く。

## Phase 6: 削除の実行

- **ユーザー承認を取ってから実行する**（候補件数・保護件数・cutoff を提示）
- **タグが付いた digest は、タグごと削除しないと消えない**ことがある（レジストリの仕様を確認する）
- 並列実行するなら**成否を 1 件ずつ記録する**

## Phase 7: 失敗の分類とリトライ

| 分類 | 対処 |
|---|---|
| 認証切れ | 再認証して**その分だけ**リトライ |
| 参照中で削除拒否 | 保護漏れのサイン。**リトライせず調査する** |
| その他 | 記録して報告 |

## Phase 8: 結果報告

削除 N 件 / 保護 M 件 / 失敗 K 件、対象 cutoff、レジストリの使用量。

🔴 **使用量の反映は非同期のことがある。** 直後の数値が減っていなくても失敗ではない。「中間値」と明記する。

## Notes

- 🔴 **「使用中の収集」と「削除」を別セッションに分けない。** 間が空くほどレースの窓が広がる
- 定期実行に載せるなら、**収集失敗時は削除せず異常終了する**設計にする（黙って 0 件保護で走らせない）
