# wording-fix-gate — 文言修正ゲート

Claude が **文言修正程度の PR だけをマージまで自走**できるようにし、機能追加・変更等の非自明な PR のマージを**機械的にブロック**するハーネス。

- 分類器: [gate.py](./gate.py) — unified diff が「文言修正程度」かを判定（fail-closed）
- ブロッカー: [premerge_hook.py](./premerge_hook.py) — PreToolUse(Bash) hook。マージコマンド（CLI / REST / GraphQL）を検知し、ゲート不合格なら exit 2 でツール実行自体を拒否する
- 登録: プロジェクトの `.claude/settings.json` の `hooks.PreToolUse`
- 運用フロー: `/merge-wording-fix` skill

## 仕組み

```text
Claude の Bash 呼び出し
  └─ premerge_hook.py (PreToolUse)
       ├─ マージコマンドでない → 素通り
       └─ マージコマンド → PR の diff を取得 → gate.py 判定
            ├─ PASS → マージ実行を許可
            └─ NG / 判定不能 / PR 特定不能 → exit 2 で block（fail-closed）
```

🔴 **hook は Claude のツール呼び出しにのみ効く。** ユーザー自身のターミナル実行は対象外なので、非文言修正 PR はユーザーが手動でマージする。**これは抜け穴ではなく設計** — 人の判断を残すための境界。

## 判定基準（gate.py）

すべて満たすこと:

- 変更ファイル数 ≤ 5 / 変更行数（+/- 合計）≤ 80
- 新規追加・削除・rename・バイナリ変更を含まない
- denylist パスを含まない（既定）: `.github/` / `.claude/` / `tools/` / migrations / `schema.prisma` / `package.json` / `tsconfig*.json` / lock / Dockerfile / `k8s/` / `.env*` / `env.mjs` / `.tf` / Makefile / `.sql` / `.yml` `.yaml` / `.sh` / `.mise*.toml`
- ドキュメント（`.md` / `.mdx` / `.txt`）: 内容自由
- コード（`.ts` / `.tsx` / `.js` / `.jsx` / `.mjs` / `.cjs` / `.py`）:
  - 各 hunk で `-` / `+` の行数が一致し、**文字列リテラルの中身 / JSX タグ間テキスト / コメントをマスクした正規化行がペアワイズ一致**（＝構造変更なし）
  - 変更されたリテラルが「文言らしい」こと（非 ASCII を含む or 空白を含む）。`"/api/x"` のような識別子・パス風リテラルの変更は不合格
- 上記以外の拡張子（`.json` 含む）: 不合格

判定不能・想定外は**すべて不合格**（fail-closed）。

### プロジェクト固有の denylist を足す

「文字列変更が挙動変更になり得る領域」はプロジェクトごとに違う。環境変数で追加する:

```bash
export WORDING_GATE_EXTRA_DENY='^config/secrets/:(^|/)tenant_settings\.py$'
```

`:` 区切りの正規表現。hook から使うなら `.claude/settings.json` の hook コマンド側で設定する。

## 使い方

```bash
# ローカル diff の事前チェック（PR 作成前）
git diff "origin/<base>...HEAD" | python3 .claude/devkit/wording-fix-gate/gate.py --stdin

# PR 単位の判定
python3 .claude/devkit/wording-fix-gate/gate.py --pr 550 --repo owner/repo
```

## hook の登録

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "python3 \"$(git rev-parse --show-toplevel)/.claude/devkit/wording-fix-gate/premerge_hook.py\"",
            "timeout": 90
          }
        ]
      }
    ]
  }
}
```

## 既知の限界（意図した設計）

- **fail-safe 優先**: 複数行に跨る JSX テキスト・テンプレートリテラルの文言変更、英単語 1 語のラベル変更（空白なしの純 ASCII）などは、文言修正でもブロックされうる → ユーザー手動マージへ
  - 🔴 **複数行 JSX は「1 行に詰めてマスクさせる」回避が成立しない。** `JSX_TEXT_RE` は `>text<` を**同一行**でしか拾わないため、フォーマッタが折り返した本文は `>` も `<` も無い素のテキスト行になり、マスクされず行全体が構造比較される。1 行にまとめても**フォーマッタが再び折り返す**ので NG のまま。**回避を試みず手動マージへ切り替える**（文字列リテラル化や定数への切り出しは行構造が変わるためやはり NG で、かつ文言修正の範囲を超える）
- コード内の文字列が挙動を持つケース（SQL 文・プロンプト等の空白入り文字列）は「文言らしい」と判定されうる。**上限 5 ファイル / 80 行・CI green 必須・PR のレビュー可視性が残りの防衛線**
- `.json`（i18n の翻訳ファイル含む）は一律不合格。緩和するなら「値のみ変更 + key 不変」の専用正規化を追加する
- hook はシェル経由の**独自マージスクリプト**を検知しない。そうした経路があるプロジェクトでは別途ブロックを用意する
- 🔴 **検知は「行頭・`;` `&` `|` の後」に現れたコマンドを拾うため、ドキュメントやヒアドキュメント本文に例として書いたコマンド文字列にも反応する。** ゲートの説明を書くときは、例示コマンドをインラインコード内に置くか行頭に来ないようにする（本 README がまさにそれで一度ブロックされた）
- 🔴 **`.claude/` / `tools/` を denylist に含めるのは、このゲート自体・skill・rules を「文言修正」名目で自己改変してマージする経路を塞ぐため。** ここを外さないこと

## 検証

ゲートを編集したら、**故意破壊で「本当に落ちるか」を実測する**（PASS するだけでは「見ていない」と区別が付かない）。最低限の 4 パターン:

1. 文言のみの変更 → PASS
2. 定数値・条件式の変更 → NG（構造差分）
3. パス風リテラルの変更 → NG（文言らしくない）
4. `WORDING_GATE_EXTRA_DENY` で対象パスを足す → NG（denylist）
