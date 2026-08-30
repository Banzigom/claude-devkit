---
name: kube-debug-db
description: Kubernetes クラスタ上の Pod 経由でマネージド DB へ接続し、psql / mysql でクエリを実行する。ephemeral container を注入して既存 Pod のサイドカー（DB プロキシ）経由で繋ぐ。「クラスタから DB に繋ぎたい」「psql したい」「kubectl debug で DB 接続」と言われた時に使用してください。
argument-hint: '[環境] [postgres|mysql]'
allowed-tools: Bash(bash *), Bash(kubectl get:*), Bash(kubectl debug:*), Bash(kubectl exec:*), Bash(kubectl cp:*), Bash(kubectl run:*), Bash(kubectl create:*), Bash(kubectl delete:*), Bash(jq *), Read, AskUserQuestion
---

# kube-debug-db — クラスタ経由の DB 接続

マネージド DB が private IP のみの構成では、ローカルから直接繋げない。**クラスタ内の Pod を踏み台にする。**

## 前提

```bash
DEVKIT_ENV=$(bash "$(git rev-parse --show-toplevel)/.claude/devkit/config.sh") || exit 1
eval "$DEVKIT_ENV"
kubectl config current-context     # 🔴 まず context。テナント / 環境を跨いだ切替で誤対象を見がち
```

## 接続方式

**既存 Pod に DB プロキシのサイドカーが同居しているなら、そこへ ephemeral container を注入するのが最短**（`localhost:<port>` で繋がる）。

```bash
kubectl debug -n <ns> <pod> --image=<psql/mysql が入った image> -it --target=<app-container> -- bash
```

🔴 **コマンドは literally `kubectl debug` から始める。** 権限の allow ルールは**前方一致**なので、次の形はいずれも一致せず拒否される:

- 先頭が変数代入（`CTX=...; kubectl debug ...`）
- サブコマンドの前にフラグ（`kubectl --context=X debug ...`）

グローバルフラグはサブコマンドの**後ろ**に置けば効く（`kubectl debug -n <ns> <pod> --context=X ...`）。

## ハマりどころ

| 症状 | 原因 / 対処 |
|---|---|
| ephemeral container が起動しない | namespace の **ResourceQuota** で `requests` / `limits` 未指定の Pod が作れないことがある。明示する |
| Pod がスケジュールされない | 専用ノードプールの **taint** に `tolerations` が要る |
| DB クライアントが入っていない | デバッグ用の汎用 image に psql / mysql が同梱されていないことがある。**DB クライアント入りの image を明示する** |
| すぐ終了する | `sleep` が短いと SIGKILL される。十分長くする |
| 環境変数が無い | ephemeral container は**元コンテナの env を継承しない**。`envFrom` / `--env` で明示注入する |
| **root で動かせない** | デバッグ用 image が root 前提でも、対象 Pod の `runAsNonRoot: true` 等の SecurityContext を継承して起動できないことがある。**ephemeral container 側の SecurityContext を明示的に上書きする** |
| `port-forward` が繋がらない | **サンドボックス化されたランタイム（gVisor 等）の Pod には通らない。** 転送は張れるが netns 内の `localhost` へ `connection refused` になる。→ **クラスタ内から Service の FQDN を叩く素の Pod を立てる**（`http://<svc>.<ns>.svc.cluster.local:<port>`） |

## 手順

1. `kubectl config current-context` で対象を確定する
2. 対象 namespace の Pod を列挙し、DB プロキシのサイドカーを持つものを選ぶ
3. ephemeral container を注入して接続する
4. **クエリを実行する前に、読み取り専用か書き込みを伴うかを宣言する。** 書き込み・削除は**ユーザー承認を取る**
5. 終わったらデバッグ用 Pod / コンテナを掃除する

## 行レベルセキュリティに注意

🔴 **アプリが使う DB ユーザーは、行レベルセキュリティをバイパスする権限を持っていることがある。** その場合、繋いだだけで**全テナント・全組織のデータが見える**。

- **テナント / 組織スコープで確認したいなら、接続後にセッション変数を明示的に設定する**（例: `SET app.current_tenant_id = '<id>';`）
- 設定せずに数えた件数を「そのテナントの件数」として報告しない（**全体の件数を報告してしまう**）

## Notes

- 🔴 **本番データへのクエリは、実行前に SQL をユーザーに提示して合意を取る**
- 取得結果に個人情報が含まれる場合、**そのまま会話やファイルへ貼らない**（件数・集計値に落とす）
- **接続できたこと自体を成果にしない。** 何を確認したくて繋いだのかを結果に書く
