---
name: tls-certificate-recovery
description: TLS 証明書の期限切れ・発行失敗を切り分けて復旧する。証明書リソースの状態確認 → 発行者の状態確認 → 再発行 → 反映確認。「証明書エラー」「証明書期限切れ」「TLS エラー」「HTTPS が繋がらない」と言われた時に使用してください。
argument-hint: '[対象ドメイン | 環境]'
allowed-tools: Bash(bash *), Bash(kubectl get:*), Bash(kubectl describe:*), Bash(kubectl delete:*), Bash(kubectl apply:*), Bash(openssl *), Bash(curl *), Bash(dig *), Bash(jq *), Read, AskUserQuestion
---

# tls-certificate-recovery — TLS 証明書の復旧

## Step 0: 症状の確認

```bash
echo | openssl s_client -connect <host>:443 -servername <host> 2>/dev/null \
  | openssl x509 -noout -dates -issuer -subject
```

**「期限切れ」「発行者が違う」「そもそも証明書が返らない」を区別する。** 症状で原因の層が変わる。

## Step 1: 証明書リソースの状態

```bash
kubectl get certificate -A
kubectl describe certificate <name> -n <ns>
```

見るところ:

- `READY` が `False` なら**発行に失敗している**（期限切れとは別問題）
- `Message` に**発行者側のエラー**が出ていることが多い
- 最終更新時刻 — **いつから失敗しているか**

🔴 **`--no-headers` の出力を `awk '{print $N}'` で読まない**（空セルで列がずれる）。`-o jsonpath` を使う。

## Step 2: 発行者（Issuer）の状態

```bash
kubectl get <issuer リソース> -A
kubectl describe <issuer リソース> <name> -n <ns>
```

**発行者の資格情報（API トークン等）が失効していると、証明書側には「発行できない」としか出ない。** 発行者まで見ないと原因に辿り着かない。

## Step 3: 原因の切り分け

| 症状 | 原因 | 対処 |
|---|---|---|
| 発行者が `Ready=False` | 資格情報の失効・権限不足 | 資格情報を更新する（**ユーザーに依頼**） |
| 証明書が `Ready=False`、発行者は正常 | 発行リクエストの失敗（レート制限 / 検証失敗） | メッセージを読む。**闇雲に再作成しない** |
| 証明書は `Ready=True` なのに期限切れの証明書が返る | **配信側が古い証明書を掴んでいる** | ロードバランサ / Ingress の反映を確認する |
| DNS が別のところを向いている | 切替漏れ | `dig` で確認する |

🔴 **証明書リソースを消して作り直す前に、発行者の状態を確認する。** 発行者が壊れていると、**消しただけで発行されず無証明書の状態になる**（症状が悪化する）。

## Step 4: 再発行

**ユーザー承認を取ってから実行する。** 再発行中は一時的に証明書が無い状態になりうる。

**発行元にレート制限があることが多い。** 短時間に何度も作り直すと制限に掛かって**その後しばらく発行できなくなる**。1 回試したら結果を待つ。

## Step 5: 反映確認

```bash
echo | openssl s_client -connect <host>:443 -servername <host> 2>/dev/null \
  | openssl x509 -noout -dates -issuer
```

🔴 **ブラウザで開いて確認しない**（キャッシュ・別経路の証明書を掴む）。**エンドポイントに対して実測する。**

## Step 6: 報告と再発防止

- 原因（層まで特定して書く）
- 実施した対処
- **同じ失敗が次の更新時期にも起きるか** — 資格情報の失効が原因なら**有効期限とローテーション計画**を残す
- **期限切れを事前に検知する仕組み**があるか（無いなら提案する）

## Notes

- 🔴 **新規に払い出した対象では、証明書の作成が他のリソースより先に必要なことがある**（発行者のカスタムリソースが未導入だと、適用そのものが失敗する）
- **証明書は期限が近づいてから自動更新される。** 「有効期限までまだある」ことと「更新が成功する」ことは別なので、**`Ready=False` を期限まで放置しない**
