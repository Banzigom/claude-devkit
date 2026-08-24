# エビデンス記録の共通規約

`verify-browser` / `audit-changes` / `fix-pr-review` が共通で使う、検証・レビューの証跡の残し方。

**「確認した」という文章だけを残さない。** 後から第三者が追えず、やっていない検証と区別が付かない。

## 保存先の準備

各スキルの実行開始時に 1 回だけ実行する。上位スキルから `$EVIDENCE_DIR` が渡っていれば**継承する**（フェーズ間で証跡を分断しないため）。

```bash
if [ -z "${EVIDENCE_DIR:-}" ]; then
  REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")
  PR_NUMBER=$(gh pr list --head "$(git branch --show-current)" --json number -q '.[0].number' 2>/dev/null)
  KEY="${PR_NUMBER:+PR-$PR_NUMBER}"; KEY="${KEY:-issue-${ISSUE_NUMBER:-none}}"
  EVIDENCE_DIR="$HOME/devkit-evidence/${REPO_NAME}/${KEY}/$(date +'%Y-%m-%d_%H%M%S')"
fi
mkdir -p "$EVIDENCE_DIR"/{screenshots,logs,recordings}
```

同一の PR / Issue に対する複数スキルの証跡が、同じ timestamp ディレクトリ配下にまとまる。

## 命名

| 種別 | パス |
|---|---|
| スクリーンショット | `screenshots/<NN>-<label>.png`（`NN` は連番） |
| ログ（試行・ラウンド単位） | `logs/<種別>-<R|C>.txt` / `.jsonl` / `.md` |
| 録画 | `recordings/<label>.gif` |
| サマリ | `summary.md` |

## 秘匿情報

🔴 **パスワード・トークン・個人情報・顧客データをログやスクリーンショットに残さない。** 入力値をそのまま出力へ書かない。

**機密性の高い環境（閉域網・規制対象データを含む環境）で取得した証跡は、外部ストレージへ上げない。** その場合はレポートに「ローカル保存のみ」と明記する。判定は対象 URL / 環境名で行い、判断が付かなければユーザーに確認する。

## 完了時のコメント

対象 PR（無ければ Issue）へ投稿する。**対応する PR / Issue が無い単発実行ならコメントは省き、`$EVIDENCE_DIR/summary.md` に同じ内容を保存してパスを提示する。**

```markdown
## <スキル名> エビデンス

- **結果**: PASS | FAIL
- **対象**: <URL / PR / diff 範囲>
- **反復**: <I/N>
- **保存先**: `<EVIDENCE_DIR>`

| 種別 | パス | 補足 |
|---|---|---|
| ... | ... | ... |

### サマリ
- <合格基準ごとの実測値>
- 失敗要因（FAIL 時）: <1-3 行>
- 次アクション: <...>
```

## Notes

- **証跡は合否判定の根拠であって、装飾ではない。** 合格基準に出てくる数値（error 件数・4xx/5xx 件数・Critical 件数）は必ずファイルに残った実測値から引く
- **取得に失敗したことと、0 件だったことを区別して書く。** 混ぜると「検証したが問題なし」と誤読される
