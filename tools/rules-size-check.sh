#!/usr/bin/env bash
#
# rules-size-check.sh — .claude/rules/ の肥大化と知見の消失を機械検証する
#
# .claude/rules/ は毎セッション自動読み込みされるためコンテキストを常時消費する。
# 「増やし続けても壊れない」ことを人の記憶に頼らず守るためのゲート。
#
#   検証 1: サイズ        — rules 合計が上限以下か / ファイル単体が上限以下か
#   検証 2: 見出し保全    — base 比較で見出し (^#) の削除・改名がゼロか（ファイル間の移動は許容）
#   検証 3: エントリ保存則 — 知見の箇条書き (^- **) の総数が base から減っていないか
#   検証 4: リンク解決    — 相対リンクの実ファイルが存在するか
#   検証 5: 釣り合わせ    — rules を増やした分だけ退避先へ移したか（ラチェット）
#
# 閾値・ディレクトリは .claude/devkit.json（rules セクション）から読む。
# フラグで個別に上書きできる。
#
# 使い方:
#   bash .claude/devkit/rules-size-check.sh
#   bash .claude/devkit/rules-size-check.sh --base origin/main --max-total 200000 --merged 6
#
# bash 3.2 (macOS 同梱) 互換で書く。連想配列・${!arr[@]} は使わない。

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# ---- 設定読み込み（devkit.json があれば採用、無ければ既定値） ----
RULES_DIR=".claude/rules"
REFERENCE_DIR="docs/rules-reference"
ARCHIVE_DIR="docs/rules-archive"
MAX_TOTAL=150000
MAX_FILE=20480
BASE_REF="main"

CONFIG_LOADER=".claude/devkit/config.sh"
if [ -f "$CONFIG_LOADER" ]; then
  if DEVKIT_ENV=$(bash "$CONFIG_LOADER" 2>/dev/null); then
    eval "$DEVKIT_ENV"
    RULES_DIR="${DEVKIT_RULES_DIR:-$RULES_DIR}"
    REFERENCE_DIR="${DEVKIT_RULES_REF_DIR:-$REFERENCE_DIR}"
    ARCHIVE_DIR="${DEVKIT_RULES_ARCHIVE_DIR:-$ARCHIVE_DIR}"
    MAX_TOTAL="${DEVKIT_RULES_MAX_TOTAL:-$MAX_TOTAL}"
    MAX_FILE="${DEVKIT_RULES_MAX_FILE:-$MAX_FILE}"
    BASE_REF="${DEVKIT_BASE_BRANCH:-$BASE_REF}"
  fi
fi

# 見出し保全・エントリ保存則は「ファイル間の移動」を許容する。移動先には
# rules-reference / rules-archive 以外の docs 配下も含まれうるので、追加で
# 走査したいディレクトリがあれば環境変数で渡す（空白区切り）。
# 入れ忘れると「移動」が「削除」と判定されて無条件 FAIL する。
EXTRA_DIRS="${DEVKIT_RULES_EXTRA_DIRS:-}"

MERGED=0
COMPARE_BASE=1
ALLOW_GROWTH=0
# この閾値までの増加は釣り合わせを求めない（1 エントリ程度の追記を毎回ブロックしない）。
BALANCE_THRESHOLD=2048

usage() {
  cat <<'USAGE'
Usage: rules-size-check.sh [options]

  --base <ref>        比較元 git ref（既定: devkit.json の baseBranch。実際の比較は HEAD との分岐点）
  --max-total <byte>  rules 合計の上限（既定: devkit.json の rules.maxTotalBytes）
  --max-file <byte>   ファイル単体の警告閾値（既定: devkit.json の rules.maxFileBytes）
  --merged <n>        統合で減らしたエントリ数の申告（既定: コミットの Merged-Entries トレーラーから自動集計）
  --no-base           base 比較（検証 2/3/5）を skip
  --allow-growth      退避なしで rules を増やすことを明示的に許可する（検証 5 を warn に落とす）
  -h, --help          このヘルプ
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE_REF="$2"; shift 2 ;;
    --max-total) MAX_TOTAL="$2"; shift 2 ;;
    --max-file) MAX_FILE="$2"; shift 2 ;;
    --merged) MERGED="$2"; shift 2 ;;
    --no-base) COMPARE_BASE=0; shift ;;
    --allow-growth) ALLOW_GROWTH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ ! -d "$RULES_DIR" ]; then
  echo "rules ディレクトリが無い: ${RULES_DIR}（/devkit-init 未実行か、rules.dir の設定違い）" >&2
  exit 2
fi

FAILED=0
fail() { echo "  ❌ $1"; FAILED=1; }
pass() { echo "  ✅ $1"; }
warn() { echo "  ⚠️  $1"; }

existing_dirs() {
  for d in "$RULES_DIR" "$REFERENCE_DIR" "$ARCHIVE_DIR" $EXTRA_DIRS; do
    [ -d "$d" ] && echo "$d"
  done
  # 最後のディレクトリが不在だと [ -d ] が偽になり関数全体が非ゼロ終了するため明示する
  return 0
}

# ---------------------------------------------------------------- 検証 1: サイズ
echo "[1/5] サイズ"

total=$(cat "$RULES_DIR"/*.md 2>/dev/null | wc -c | tr -d ' ')
file_count=$(ls -1 "$RULES_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
echo "  ${RULES_DIR}: ${total} B / ${file_count} ファイル (上限 ${MAX_TOTAL} B)"

if [ "$total" -le "$MAX_TOTAL" ]; then
  pass "合計 ${total} B <= ${MAX_TOTAL} B"
else
  fail "合計 ${total} B が上限 ${MAX_TOTAL} B を超過 (超過 $((total - MAX_TOTAL)) B)"
fi

oversized=0
for f in "$RULES_DIR"/*.md; do
  [ -e "$f" ] || continue
  size=$(wc -c < "$f" | tr -d ' ')
  if [ "$size" -gt "$MAX_FILE" ]; then
    warn "$(basename "$f") が ${size} B (ファイル上限 ${MAX_FILE} B)"
    oversized=$((oversized + 1))
  fi
done
[ "$oversized" -eq 0 ] && pass "ファイル単体の上限超過なし"

# ------------------------------------------------------ base 比較の可否を判定
#
# 比較対象は base の「現在の tip」ではなく「分岐点 (merge-base)」にする。
# tip を使うと、自分の PR が rules に一切触れていなくても、レビュー待ちの間に
# 並走 PR がマージされるだけで base 側のエントリ数が増えて FAIL する。
BASE_SHA=""
if [ "$COMPARE_BASE" -eq 1 ]; then
  RESOLVED=""
  for ref in "origin/$BASE_REF" "$BASE_REF"; do
    if git rev-parse --verify --quiet "$ref" >/dev/null; then RESOLVED="$ref"; break; fi
  done
  if [ -z "$RESOLVED" ]; then
    echo "  base ref '$BASE_REF' が解決できないため検証 2/3 を skip"
    COMPARE_BASE=0
  else
    BASE_SHA=$(git merge-base "$RESOLVED" HEAD 2>/dev/null || true)
    if [ -z "$BASE_SHA" ]; then
      BASE_SHA=$(git rev-parse "$RESOLVED")
      echo "  merge-base が取れないため tip ($RESOLVED) と比較する"
    fi
  fi
fi

# コードフェンス内を除去する。rules には PR 本文テンプレや書き方の例をフェンスで
# 囲んだ箇所が多く、その中の `#` 行・`- **` 行は本物の見出し・知見ではない。
# 除外しないと (a) 例文の追加が本物の知見削除を相殺して検知漏れ、
# (b) 例文内の見出し編集が「見出しの削除」として誤検知、の両方が起きる。
strip_fences() {
  awk '
    /^````*/ { fence = !fence; next }
    !fence   { print }
  '
}

# README.md は判定基準・使い方を書いた説明文書であって知見の格納先ではないため、
# エントリ数のカウント（検証 3）を歪めないよう除外する。
dump_base() {
  git ls-tree -r --name-only "$BASE_SHA" -- $(existing_dirs) 2>/dev/null \
    | grep '\.md$' | grep -v '/README\.md$' \
    | while read -r path; do
        git show "$BASE_SHA:$path" 2>/dev/null | strip_fences || true
        echo
      done
}

dump_current() {
  find $(existing_dirs) -name '*.md' -type f | grep -v '/README\.md$' | sort \
    | while read -r path; do
        strip_fences < "$path"
        echo
      done
}

# ------------------------------------------------------- 検証 2: 見出し保全
echo "[2/5] 見出し保全 (base: ${BASE_REF} の分岐点)"

if [ "$COMPARE_BASE" -eq 0 ]; then
  echo "  skip"
else
  base_head=$(mktemp); cur_head=$(mktemp)
  trap 'rm -f "$base_head" "$cur_head"' EXIT

  dump_base    | grep '^#' | sed 's/[[:space:]]*$//' | sort -u > "$base_head"
  dump_current | grep '^#' | sed 's/[[:space:]]*$//' | sort -u > "$cur_head"

  missing=$(comm -23 "$base_head" "$cur_head" || true)
  if [ -z "$missing" ]; then
    pass "見出しの削除・改名なし ($(wc -l < "$base_head" | tr -d ' ') 件を検査)"
  else
    fail "base にあった見出しが消えている:"
    echo "$missing" | sed 's/^/       /'
  fi
fi

# --------------------------------------------------- 検証 3: エントリ保存則
echo "[3/5] 知見エントリ保存則"

if [ "$COMPARE_BASE" -eq 0 ]; then
  echo "  skip"
else
  base_entries=$(dump_base    | grep -c '^- \*\*' || true)
  cur_entries=$(dump_current  | grep -c '^- \*\*' || true)

  # --merged 未指定なら、分岐点以降のコミットメッセージの
  #   Merged-Entries: <n>
  # トレーラーを合計する。CI からフラグを渡す経路が無いため、統合を含む PR は
  # コミットメッセージで申告する。
  if [ "$MERGED" -eq 0 ]; then
    MERGED=$(git log --format=%B "$BASE_SHA..HEAD" 2>/dev/null \
      | sed -n 's/^Merged-Entries:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
      | awk '{ s += $1 } END { print s + 0 }')
  fi
  allowed=$((base_entries - MERGED))

  echo "  base ${base_entries} 件 / 現在 ${cur_entries} 件 / 統合申告 ${MERGED} 件"
  if [ "$cur_entries" -ge "$allowed" ]; then
    pass "エントリ総数 ${cur_entries} >= ${allowed} (知見の消失なし)"
  else
    fail "エントリが ${allowed} 件を下回る (${cur_entries} 件)。統合したならコミットメッセージに Merged-Entries: <n> を書く"
  fi
fi

# ------------------------------------------------------- 検証 4: リンク解決
echo "[4/5] 相対リンク解決"

broken=0
checked=0
for f in $(find $(existing_dirs) -name '*.md' -type f | sort); do
  dir=$(dirname "$f")
  # ](...) 形式のリンク先を抽出する。
  #   - コードフェンス内は書き方の例であって実リンクではないので除外
  #   - インラインコード内（Markdown 記法の説明）も同様に除外
  #   - 絶対 URL / mailto / 同一ファイル内アンカーは除外
  links=$(strip_fences < "$f" 2>/dev/null \
    | sed 's/`[^`]*`//g' \
    | grep -oE '\]\([^)]*\)' \
    | sed 's/^](//; s/)$//' \
    | grep -vE '^(https?:|mailto:|#)' || true)
  [ -z "$links" ] && continue
  while IFS= read -r link; do
    [ -z "$link" ] && continue
    target="${link%%#*}"          # アンカーを除去
    [ -z "$target" ] && continue  # 同一ファイル内アンカーのみ
    # 本文中の説明用プレースホルダは実リンクではないので除外
    case "$target" in
      *...*) continue ;;
    esac
    checked=$((checked + 1))
    if [ ! -e "$dir/$target" ]; then
      fail "$f: リンク先が存在しない -> $link"
      broken=$((broken + 1))
    fi
  done <<EOF
$links
EOF
done
[ "$broken" -eq 0 ] && pass "相対リンク ${checked} 件すべて解決"

# ------------------------------------------- 検証 5: 追記と退避の釣り合わせ
#
# rules の肥大化が繰り返される原因は、**追記だけを行い削減と非対称**なこと。
# 「気づいた人が後でアーカイブして帳尻を合わせる」運用では再発が止まらないので、
# **増やした変更自身に同等バイトの退避を求める**。
#
# 退避先は reference / archive のどちらも自動読み込みされないので、そこへ動かせば
# 常駐コンテキストは減る。**消すのではなく動かす**のが原則（検証 2/3 が消失を別途禁じている）。
#
# 判定は「rules の増加 <= 退避先の増加」。純粋な新規知見でも、同じ変更で同じだけ
# 退避すれば通る。**本当に出せるものが無いときは --allow-growth で宣言する**
# （黙って増やせない形にするためのフラグ）。
echo "[5/5] 追記と退避の釣り合わせ"

if [ "$COMPARE_BASE" -eq 0 ]; then
  echo "  skip"
else
  # 対象ディレクトリの .md を連結したバイト数。base 側は git show で拾う。
  # 実在しないディレクトリは 0 B 扱い（新設された退避先も差分として正しく効く）。
  # 走査結果が空のとき find / grep は非ゼロで終わる。set -euo pipefail の下では
  # それだけでスクリプトが**無言で終了する**（検証 5 の出力が丸ごと消え、
  # 「実行されたが違反 0 件」と区別が付かない）。各段で明示的に握って 0 B に倒す。
  bytes_current() {
    [ -d "$1" ] || { echo 0; return; }
    out=$(find "$1" -name '*.md' -type f -print0 2>/dev/null \
      | xargs -0 cat 2>/dev/null | wc -c | tr -d ' ' || true)
    echo "${out:-0}"
  }
  bytes_base() {
    paths=$(git ls-tree -r --name-only "$BASE_SHA" -- "$1" 2>/dev/null | grep '\.md$' || true)
    [ -n "$paths" ] || { echo 0; return; }
    out=$(echo "$paths" | while read -r path; do
            git show "$BASE_SHA:$path" 2>/dev/null || true
          done | wc -c | tr -d ' ' || true)
    echo "${out:-0}"
  }

  rules_now=$(bytes_current "$RULES_DIR")
  rules_base=$(bytes_base "$RULES_DIR")
  offload_now=$(( $(bytes_current "$REFERENCE_DIR") + $(bytes_current "$ARCHIVE_DIR") ))
  offload_base=$(( $(bytes_base "$REFERENCE_DIR") + $(bytes_base "$ARCHIVE_DIR") ))

  rules_delta=$((rules_now - rules_base))
  offload_delta=$((offload_now - offload_base))
  echo "  base 比: rules ${rules_delta} B / 退避先 ${offload_delta} B"

  if [ "$rules_delta" -le "$BALANCE_THRESHOLD" ]; then
    pass "rules の増加が ${BALANCE_THRESHOLD} B 以下 (${rules_delta} B)"
  elif [ "$offload_delta" -ge "$rules_delta" ]; then
    pass "退避 ${offload_delta} B >= 追記 ${rules_delta} B"
  elif [ "$ALLOW_GROWTH" -eq 1 ]; then
    warn "退避 ${offload_delta} B < 追記 ${rules_delta} B だが --allow-growth で許可された"
  else
    fail "rules が ${rules_delta} B 増えているのに退避が ${offload_delta} B しかない"
    echo "       同じ変更で ${REFERENCE_DIR} か ${ARCHIVE_DIR} へ同等バイトを移すこと"
    echo "       (判定基準: .claude/rules/README.md の P1〜P5 / A1〜A4)"
    echo "       本当に出せるものが無ければ --allow-growth を付けて宣言する"
  fi
fi

# ------------------------------------------------------------------- 結果
echo
if [ "$FAILED" -eq 0 ]; then
  echo "rules-size-check: PASS"
else
  echo "rules-size-check: FAIL"
fi
exit "$FAILED"


