---
name: devkit-update
description: 導入済みの claude-devkit をプラグインの最新版に追従させる。.claude/devkit/ のスクリプトを差分表示してから更新し、devkit.json に増えた任意キーを既存値を変えずに補完する。「devkit を更新」「devkit-update」「ハーネス最新化」「プラグインを上げたので追従して」と言われた時に使用してください。
argument-hint: '[--check]'
allowed-tools: Bash(git *), Bash(jq *), Bash(cp *), Bash(diff *), Bash(mkdir *), Bash(chmod *), Bash(ls *), Bash(cat *), Bash(test *), Bash(bash *), Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# devkit-update — 導入済み devkit の追従

`/devkit-init` は `tools/` を**コピー**で持たせる。プラグインを更新してもプロジェクト側が壊れない代わりに、**プラグイン側のバグ修正も自動では届かない**。その差分を明示的に取り込むのがこの skill。

`$ARGUMENTS`:

- `--check`: 差分の報告だけで、ファイルを一切書き換えない

## 設計意図

- **黙って上書きしない。** `.claude/devkit/` はプロジェクトが手を入れていることがある。何が変わるかを見せてから合意を取る
- **`.claude/devkit.json` の既存値は絶対に変えない。** 追従するのはスクリプトと「増えた任意キー」だけ
- **入っていないものを勝手に増やさない。** `wording-fix-gate` を使っていないプロジェクトに新規配置しない（`/devkit-init` と同じ「全部入りを前提にしない」方針）

## 手順

### 1. 版の確認

```bash
PLUGIN="${CLAUDE_PLUGIN_ROOT:?プラグイン root が取れない。plugin 経由で起動されているか確認する}"
ROOT=$(git rev-parse --show-toplevel)
test -d "$ROOT/.claude/devkit" || { echo "未導入。先に /devkit-init を実行する"; exit 1; }

NEW=$(jq -r '.version' "$PLUGIN/.claude-plugin/plugin.json")
CUR=$(cat "$ROOT/.claude/devkit/VERSION" 2>/dev/null || echo "unknown")
echo "installed=${CUR} / plugin=${NEW}"
```

🔴 **`unknown`（VERSION が無い）は「最新」ではなく「不明」。** 版を刻む前に導入されたということなので、**必ず差分を取ってから**判断する。取得失敗と 0 件を混同しない。

### 2. 差分の列挙

**版が同じでも差分を取る。** 版は「いつコピーしたか」しか語らず、プロジェクト側の手入れは版に現れない。

```bash
for f in config.sh rules-size-check.sh project-items-fetch.sh; do
  test -f "$ROOT/.claude/devkit/$f" || continue          # 入れていないものは対象外
  diff -u "$ROOT/.claude/devkit/$f" "$PLUGIN/tools/$f" && echo "same: $f"
done
test -d "$ROOT/.claude/devkit/wording-fix-gate" \
  && diff -ru "$ROOT/.claude/devkit/wording-fix-gate" "$PLUGIN/tools/wording-fix-gate"
```

差分を 3 つに仕分けて提示する:

| 種別 | 見分け方 | 扱い |
|---|---|---|
| **プラグイン側の更新** | プロジェクト側が元の版のまま | そのまま上書きしてよい |
| **プロジェクト側の手入れ** | プラグイン側に無い変更が入っている | 🔴 **上書き前に必ず確認を取る。** 意図的な改変を無言で消すのは不可逆 |
| **両方が変わっている** | 双方に変更 | 手でマージする。自動では解決しない |

### 3. 更新の実行（`--check` なら skip）

ユーザーの承認を得てからコピーする。**入っていないファイルを新規に増やさない。**

```bash
for f in config.sh rules-size-check.sh project-items-fetch.sh; do
  test -f "$ROOT/.claude/devkit/$f" && cp "$PLUGIN/tools/$f" "$ROOT/.claude/devkit/$f"
done
test -d "$ROOT/.claude/devkit/wording-fix-gate" \
  && cp -r "$PLUGIN/tools/wording-fix-gate/." "$ROOT/.claude/devkit/wording-fix-gate/"
chmod +x "$ROOT"/.claude/devkit/*.sh
jq -r '.version' "$PLUGIN/.claude-plugin/plugin.json" > "$ROOT/.claude/devkit/VERSION"
```

### 4. devkit.json に増えた任意キーの補完

テンプレに増えたキーのうち、プロジェクトの `devkit.json` に無いものを列挙する。

```bash
jq -n --slurpfile tpl "$PLUGIN/templates/devkit.full-example.json" \
      --slurpfile cur "$ROOT/.claude/devkit.json" \
  '($tpl[0]|keys) - ($cur[0]|keys)'
```

🔴 **既存キーの値は 1 つも変えない。** 提案するのは「無いキーの追加」だけで、それも**用途を説明して合意を取ってから**書く。使う予定が無いキーは足さない（空欄が増えるだけで、次に読む人が「埋めるべきなのか」を調べる羽目になる）。

### 5. 動作確認

配置し直した直後に**必ず実行する**。壊れた設定ローダを置いたことに気づけるのはここだけ。

```bash
DEVKIT_ENV=$(bash "$ROOT/.claude/devkit/config.sh") || echo "設定エラー"
eval "$DEVKIT_ENV"; echo "repo=$DEVKIT_REPO base=$DEVKIT_BASE_BRANCH"
test -f "$ROOT/.claude/rules/README.md" && bash "$ROOT/.claude/devkit/rules-size-check.sh" --no-base
```

### 6. 報告

```
devkit-update 完了
- 版: <旧> → <新>
- 更新したファイル: <名前...>
- 手入れを検出して据え置いたファイル: <名前>（理由: <...>）
- devkit.json に追加したキー: <名前>（値: <...>） / 追加しなかったキー: <名前>（理由: 使わない）
- 動作確認: config.sh exit 0 / rules-size-check exit 0
```

## 合格基準

- `config.sh` が exit 0 で `DEVKIT_REPO` を出力する
- `.claude/devkit/VERSION` がプラグインの version と一致する
- `.claude/devkit.json` の**既存キーの値が更新前と 1 つも変わっていない**（`git diff .claude/devkit.json` で確認する）
- 上書きしたファイルについて、何が変わったかを報告に書いた

## Notes

- **差分が無くても版だけ書き直す**のは構わない（次回の判断材料になる）
- プロジェクト側の手入れが恒久的に必要なら、それは devkit 側に還元すべき差分である可能性が高い。`/harvest` で知見として残すか、プラグインへ issue を立てる
- この skill は `.claude/rules/` と `.claude/settings.json` に触らない。rules は各プロジェクトが SoT、settings.json は他の hook と同居するため
