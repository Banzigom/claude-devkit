---
name: app-log-monitor
description: 稼働中アプリケーションのログを確認・監視する。対象環境とサービスを先に確認し、エラー抽出・Pod 状態・リソース使用率まで見て切り分ける。「ログ確認」「ログ監視」「エラーログ」「Pod のログ見て」と言われた時に使用してください。
argument-hint: '[環境] [サービス名]'
allowed-tools: Bash(bash *), Bash(kubectl get:*), Bash(kubectl logs:*), Bash(kubectl describe:*), Bash(kubectl top:*), Bash(docker ps:*), Bash(docker logs:*), Bash(docker compose logs:*), Bash(gcloud logging read:*), Bash(aws logs:*), Bash(jq *), Read, AskUserQuestion
---

# app-log-monitor — 稼働ログの確認・監視

## 基本方針

- 🔴 **対象環境・サービスをユーザーに確認してから実行する**（本番のログを勝手に開かない）
- 認証・クラスタ接続が済んでいることを前提とする。済んでいなければ**対話が必要な認証はユーザーに依頼する**

## 手順

### 1. 対象の確認

```bash
DEVKIT_ENV=$(bash "$(git rev-parse --show-toplevel)/.claude/devkit/config.sh") || exit 1
eval "$DEVKIT_ENV"
jq -r '.infra | {platform, environments, services, namespacePattern, clusterPattern}' "$DEVKIT_CONFIG"
```

確認する項目: **環境**（`infra.environments`）/ **サービス**（`infra.services`。省略時は全サービス）/ **目的**（エラー調査 / リリース後監視 / 一般確認）。

`infra.platform` が未設定なら、**どこで動いているかをユーザーに聞く**（推測でコマンドを打たない）。

### 2. 接続

`infra.clusterPattern` / `namespacePattern` からクラスタ名と namespace を組み立てる。接続に失敗したら:

- **リージョン / ゾーンの候補が複数ある構成では他候補も試す**（クラスタが片方にしか無い構成がある）
- 認証状態を確認する。**対話的な再認証はユーザーに依頼する**

### 3. ログの確認

| 目的 | 例（Kubernetes） |
|---|---|
| 直近のログ | `kubectl logs -n <ns> deployment/<svc> --tail=200` |
| エラー抽出 | `kubectl logs -n <ns> deployment/<svc> --tail=500 \| grep -iE "error\|exception\|fatal"` |
| 追従 | `kubectl logs -f -n <ns> deployment/<svc>` |
| 横断 | 各サービスに対して `--tail=100` |

🔴 **アプリのログに何も出ていないことを「リクエストが届いていない」と読まない。** エラーハンドリングがログ出力を条件付きにしている（デバッグフラグ付き等）と、**利用者にエラーを返しながらログには 1 行も残らない**。ログが静かなときは、(a) そのコードパスに本当にログ出力があるか実装を読む、(b) 別のエラー収集経路（監視 SaaS・アクセスログ・上流プロキシのログ）を見る。

🔴 **ログの保持期間・ローテーションに注意。** 短命な Pod（Job / CronJob）はログが即消えることがあるので、コンテナのログではなくログ集約基盤側で引く。

### 4. 追加調査

- Pod 一覧と再起動回数: `kubectl get pods -n <ns>`
- 異常 Pod の詳細: `kubectl describe pod -n <ns> -l app=<svc>`
- リソース使用率: `kubectl top pod -n <ns>`

🔴 **`--no-headers` の出力を `awk '{print $N}'` で読まない。** 空セルの行は列自体が消えて**隣の列を拾って誤判定する**。構造化フィールドは `-o jsonpath` で読む（未設定なら空文字が返るので判定できる）。

### 5. 結果報告

エラーの有無と内容 / Pod の状態（Running / CrashLoopBackOff 等）/ 異常な再起動の有無 / 次のアクション提案。

**「取得できなかった」と「0 件だった」を区別して書く。**
