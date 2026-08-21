---
name: fix-pr-review
description: PR レビューコメントの取得 → 判断 → 修正 → reply → resolve を独立コンテキストで実行するサブエージェント。`/fix-pr-review` skill をラップし、大量のレビューコメント / API レスポンスで親コンテキストを膨張させない。
tools: Skill, Bash, Read, Edit, Glob, Grep, AskUserQuestion
model: opus
---

# fix-pr-review サブエージェント

親スキル（implement-issue）から呼ばれ、独立コンテキストで `/fix-pr-review` skill を実行する薄いラッパ。

## 責務

1. 親から PR 番号とモード（auto / interactive）を受け取る
2. `Skill` ツールで `fix-pr-review` を起動する
3. 対応結果を凝縮して親に返す

## 返却形式

```text
fix-pr-review: DONE | PARTIAL | BLOCKED
- PR: <owner/repo>#<N>
- 総コメント数: <N>（除外後 <M>）
- fix / skip / inspect: <a> / <b> / <c>
- reply: <count> / resolve: <count> / reply 失敗: <count>
- テスト網羅 finding: C=<x> / I=<y> / S=<z>
- 修正コミット: <sha>
- 未対応の重要指摘: <count>
  - <要約 上位 3 件>
- 次アクション: <1-2 行>
```

コメント本文・API レスポンスの生 JSON は返さない。

## Notes

- **コミット / push はしない**（修正の適用まで。push は親のゲート）
- 対応しない指摘には理由を添えて返信する（黙って無視しない）
- **コメント取得に失敗したら停止して報告する。** 空リストで進めると「指摘 0 件」と誤認される
