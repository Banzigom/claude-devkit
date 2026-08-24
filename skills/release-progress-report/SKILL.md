---
name: release-progress-report
description: GitHub Project の現在イテレーション（リリース）に属する Issue を Status 別に集計してレポートを生成し、設定があればチャットへ投稿する。「今回のリリース分の進捗を確認して」「進捗確認して」「リリース進捗」「release-progress-report」と言われた時に使用してください。
argument-hint: '[iteration名（省略時は現在）]'
allowed-tools: Bash(bash *), Bash(gh *), Bash(jq *), Bash(date *), Read, AskUserQuestion
---

# release-progress-report — リリース進捗レポート

GitHub Project の**現在イテレーション**に属する Issue を Status 別に集計する。個別に「この Issue の進捗は？」と聞いて回る工程を削減し、各担当者が Status を更新することで進捗を可視化する運用を支える。

`tracker.type` が `github-project` でなければ使えない。

## 実行上の重要な注意（必読）

- 🔴 **Bash ツールは呼び出しごとに新しいシェルになり、変数は次の呼び出しへ引き継がれない。** イテレーション判定 → 抽出 → 集計のように**変数を跨ぐ一連の処理は必ず 1 回の Bash 呼び出し内で完結させる。** 分割すると変数が空になり、**誤ったフィルタ結果が出ても気付きにくい**（別イテレーション分を拾う等）
- 🔴 **全件取得は `bash .claude/devkit/project-items-fetch.sh`（約 10 pt）を使う。** `gh project item-list --limit N` は同じ取得に item 数ぶんのコストがかかる。カーソルページングなので `--limit` の動的算出も不要で、取りこぼしが原理的に起きない

## 手順

### 1. 対象イテレーションの決定 + 取得 + 抽出（単一 Bash 呼び出し）

```bash
DEVKIT_ENV=$(bash .claude/devkit/config.sh) || exit 1
eval "$DEVKIT_ENV"
[ "$DEVKIT_TRACKER" = "github-project" ] || { echo "tracker.type が github-project でないため利用不可"; exit 0; }

TODAY=$(TZ="$DEVKIT_SCHED_TZ" date +%Y-%m-%d)
bash .claude/devkit/project-items-fetch.sh /tmp/rpr_items.json    # 毎回 fresh

CUR="${1:-$(jq -r --arg t "$TODAY" '[.items[].iteration//empty]|unique_by(.title)
  |map(select(.startDate<=$t))|sort_by(.startDate)|last|.title//"-"' /tmp/rpr_items.json)}"

jq --arg it "$CUR" '[.items[]
  | select(.content.type=="Issue")
  | select((.iteration.title // "") == $it)
  | {n:.content.number, t:.content.title, s:.status,
     a:(.assignees|join(",")), u:.content.url}]' /tmp/rpr_items.json > /tmp/rpr_target.json

echo "iteration=[$CUR] 対象 $(jq length /tmp/rpr_target.json) 件"
```

- **リリース予定日は、イテレーションの `duration` からではなくタイトルに埋め込まれた日付表記を正として算出する。** sprint 期間は実際のリリース日と一致しないことがある。タイトルから日付を取れない場合のみ `startDate + duration` を目安としてフォールバックし、**その旨を明記する**
- 対象 0 件なら「対象イテレーション `<title>` に Issue が見つかりませんでした」と報告して終了する（投稿はしない）
- 🔴 **ユーザーに見せる前に Project のボード表示と件数を突き合わせて検算する**（キャッシュ・タイムゾーンずれ等で乖離しうる）。突き合わせできない場合は**ドラフトに「未検算」と明記する**

### 2. Status 別の集計

`tracker.releaseStatusOrder` の順にグルーピングする。

🔴 **正規順序に無い Status（Project 側で option が追加・リネームされて設定が追従できていないケース）で Issue が黙って欠落しないよう、未知 Status は末尾に回して明示的に出す:**

```bash
ORDER=$(jq -c '.tracker.releaseStatusOrder // []' "$DEVKIT_CONFIG")
jq --argjson order "$ORDER" '
  (group_by(.s) | map({status:.[0].s, items:.})) as $groups
  | ($groups | map(select(.status as $s | ($order | index($s)) == null))) as $unknown
  | ([$order[] as $s | $groups[] | select(.status==$s)]) as $known
  | $known + $unknown
' /tmp/rpr_target.json > /tmp/rpr_grouped.json

UNKNOWN=$(jq --argjson order "$ORDER" '[.[] | select(.status as $s | ($order|index($s))==null)] | length' /tmp/rpr_grouped.json)
[ "$UNKNOWN" -gt 0 ] && echo "⚠️ 正規順序に無い Status が ${UNKNOWN} 種類。tracker.releaseStatusOrder が古い可能性あり"
```

未知 Status のグループは**レポート本文にも「⚠️ 未登録 Status: `<名前>`（N 件）」として明示的に列挙する**（既知 Status に黙って混ぜない）。

### 3. レポート生成

```
## リリース進捗レポート: <イテレーション名>

期間: <startDate> 〜 <終了日目安>（残り <N> 日）
集計時刻: <now>

**In progress（3件）**
- #123 <タイトル> (@login)
- #145 <タイトル> (未アサイン)

**<次の Status>（2件）**
- ...

---
Project: <Project URL>
```

- **0 件の Status は省略してよい**（レポートを短く保つ）
- 🔴 **遅延判定・オンスケ判定はしない。** Status 別の一覧表示に徹する（評価は人に委ねる）。残り日数は参考情報として添えるだけ
- **assignee は GitHub の login をそのまま書く。** チャット ID へ変換しない（**誤爆メンションを防ぐため**）

### 4. 投稿（`report.slackChannelId` がある場合のみ）

チャット投稿ツールが使える環境なら、設定されたチャンネルへ投稿してパーマリンクを提示する。**設定が無い / ツールが無い場合はレポート本文を出力するだけで終わる**（投稿できなかったことを明記する）。

**手動実行では投稿前にドラフトを見せて確認を取る。** 無人実行（定期実行）では確認を省いてよいが、その場合も検算結果はレポートに残す。

## 合格基準

- 対象イテレーションを正しく特定できている
- イテレーション判定〜抽出〜集計を**単一 Bash 呼び出し内で完結**させている
- Project データを毎回 fresh 取得している
- 正規順序に無い Status を黙って欠落させず、末尾に明示している
- 遅延判定をせず一覧表示に徹している
- 投稿前にボード表示と件数を突き合わせている（できない場合は明記）
- 対象 0 件なら投稿せず報告のみ

## Notes

- **Status を動かす責務は各担当者側にある。** このスキルは「見える化」まで
- 定期実行に載せるなら、**ロジックを複製せず本ファイルを読んで従う形にする**（複製すると片方だけ更新されて食い違う）
