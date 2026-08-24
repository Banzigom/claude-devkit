#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""wording-fix-gate: unified diff が「文言修正程度」かを機械判定する (fail-closed)。

「文言修正程度」の定義（すべて満たすこと）:
  - 変更ファイル数 <= MAX_FILES / 変更行数(+/-合計) <= MAX_CHANGED_LINES
  - 新規追加・削除・rename・バイナリ変更を含まない（既存ファイルの修正のみ）
  - denylist パス（CI 設定 / .claude / migrations / schema / lock / env / terraform /
    k8s / shell / SQL / YAML 等、文字列変更が挙動変更になり得る領域）を含まない
  - ドキュメント (.md/.mdx/.txt): 内容自由
  - コード (.ts/.tsx/.js/.jsx/.mjs/.cjs/.py): 変更行の差分が
    「文字列リテラルの中身 / JSX タグ間テキスト / コメント」に閉じている
    （リテラルをマスクした正規化行が - / + でペアワイズ一致すること）
  - 変更された文字列リテラルは「文言らしい」こと（非 ASCII を含む or 空白を含む。
    "/api/x" のような識別子・パス風リテラルの変更は文言と見なさない）

判定不能・想定外はすべて不合格（fail-closed）。合格 exit 0 / 不合格 exit 1。

denylist はプロジェクト固有の「文字列変更が挙動変更になり得る領域」を足せる。
環境変数 WORDING_GATE_EXTRA_DENY に正規表現を `:` 区切りで渡す
（例: WORDING_GATE_EXTRA_DENY='^config/secrets/:(^|/)tenant_settings\.py$'）。

使い方:
  git diff origin/<base>...HEAD | python3 .claude/devkit/wording-fix-gate/gate.py --stdin
  python3 .claude/devkit/wording-fix-gate/gate.py --pr 123 --repo owner/repo
"""

import argparse
import os
import re
import subprocess
import sys

MAX_FILES = 5
MAX_CHANGED_LINES = 80

# 文字列変更ですら挙動変更になり得る領域・自動マージ経路から自己改変可能な領域
DENY_PATH_PATTERNS = [
    r"^\.github/",
    r"^\.claude/",
    r"^tools/",
    r"(^|/)migrations/",
    r"schema\.prisma$",
    r"(^|/)package\.json$",
    r"(^|/)tsconfig[^/]*\.json$",
    r"\.lock$",
    r"(^|/)yarn\.lock$",
    r"(^|/)package-lock\.json$",
    r"(^|/)Dockerfile",
    r"(^|/)k8s/",
    r"(^|/)\.env",
    r"(^|/)env\.mjs$",
    r"\.tf$",
    r"(^|/)Makefile$",
    r"\.sql$",
    r"\.ya?ml$",
    r"\.sh$",
    r"\.mise[^/]*\.toml$",
]

# プロジェクト固有の denylist を環境変数で足す（`:` 区切りの正規表現）。
# 不正な正規表現は「判定不能」なので fail-closed に倒す（後段の evaluate で例外→NG）。
_extra = os.environ.get("WORDING_GATE_EXTRA_DENY", "").strip()
if _extra:
    DENY_PATH_PATTERNS = DENY_PATH_PATTERNS + [p for p in _extra.split(":") if p]

DOC_EXTS = {".md", ".mdx", ".txt"}
JS_EXTS = {".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"}
PY_EXTS = {".py"}
CODE_EXTS = JS_EXTS | PY_EXTS

STR_RE = re.compile(r'"(?:[^"\\]|\\.)*"' r"|'(?:[^'\\]|\\.)*'" r"|`(?:[^`\\]|\\.)*`")
JSX_TEXT_RE = re.compile(r">([^<>{}]+)<")


def _mask_line(line, ext):
    """行を正規化し (正規化行, 変更検査対象リテラル内容のリスト) を返す。

    文字列リテラル・JSX タグ間テキストを § にマスクして構造だけを残す。
    コメント（行全体 / 行末）はマスクし、内容はリテラル検査の対象外。
    """
    literals = []

    def _collect(m):
        literals.append(m.group(0).strip("\"'`"))
        return m.group(0)[0] + "§" + m.group(0)[-1]

    s = STR_RE.sub(_collect, line.rstrip())

    def _collect_jsx(m):
        literals.append(m.group(1))
        return ">§<"

    if ext in JS_EXTS:
        s = JSX_TEXT_RE.sub(_collect_jsx, s)
        # 行末コメント（文字列マスク後に残る // はコメント）
        s = re.sub(r"//.*$", "//§", s)
        stripped = s.strip()
        if re.match(r"^(//|\*|/\*|\{/\*)", stripped):
            return "§COMMENT§", []
    elif ext in PY_EXTS:
        s = re.sub(r"#.*$", "#§", s)
        if s.strip().startswith("#"):
            return "§COMMENT§", []
    return s, literals


def _is_texty(s):
    """文言らしいリテラルか（非 ASCII を含む or 内部に空白を含む）。"""
    if re.search(r"[^\x00-\x7f]", s):
        return True
    return " " in s.strip()


def _check_pair(old, new, ext):
    """- 行と + 行のペアが「文言のみの変更」なら None、そうでなければ理由を返す。"""
    o_norm, o_lits = _mask_line(old, ext)
    n_norm, n_lits = _mask_line(new, ext)
    if o_norm != n_norm:
        return "構造差分あり: `%s` -> `%s`" % (old.strip()[:80], new.strip()[:80])
    if len(o_lits) != len(n_lits):
        return "リテラル数不一致: `%s`" % old.strip()[:80]
    for a, b in zip(o_lits, n_lits):
        if a != b and not (_is_texty(a) or _is_texty(b)):
            return "文言らしくないリテラル変更（識別子/パスの可能性）: %r -> %r" % (a[:60], b[:60])
    return None


class FileDiff(object):
    def __init__(self, path):
        self.path = path
        self.new_file = False
        self.deleted = False
        self.renamed = False
        self.binary = False
        self.hunks = []  # list of (minus_lines, plus_lines)


def parse_diff(text):
    files = []
    cur = None
    minus, plus = [], []
    in_hunk = False

    def _flush_hunk():
        if cur is not None and (minus or plus):
            cur.hunks.append((list(minus), list(plus)))
        del minus[:]
        del plus[:]

    for raw in text.splitlines():
        if raw.startswith("diff --git "):
            _flush_hunk()
            in_hunk = False
            m = re.match(r'diff --git "?a/(.*?)"? "?b/(.*?)"?$', raw)
            path = m.group(2) if m else raw
            cur = FileDiff(path)
            files.append(cur)
        elif cur is None:
            continue
        elif raw.startswith("@@"):
            _flush_hunk()
            in_hunk = True
        elif not in_hunk:
            if raw.startswith("new file mode"):
                cur.new_file = True
            elif raw.startswith("deleted file mode"):
                cur.deleted = True
            elif raw.startswith("rename from") or raw.startswith("similarity index"):
                cur.renamed = True
            elif raw.startswith("Binary files") or raw.startswith("GIT binary patch"):
                cur.binary = True
        else:
            if raw.startswith("-"):
                minus.append(raw[1:])
            elif raw.startswith("+"):
                plus.append(raw[1:])
            elif raw.startswith("\\"):
                continue  # \ No newline at end of file
    _flush_hunk()
    return files


def evaluate(diff_text):
    """(ok: bool, report: str) を返す。例外時も呼び出し側で不合格に倒すこと。"""
    reasons = []
    if not diff_text or not diff_text.strip():
        return False, "diff が空（取得失敗 or 差分なし）"

    files = parse_diff(diff_text)
    if not files:
        return False, "diff を解析できない（unified diff 形式でない）"

    if len(files) > MAX_FILES:
        reasons.append("変更ファイル数 %d > 上限 %d" % (len(files), MAX_FILES))

    total_lines = 0
    for f in files:
        ext = os.path.splitext(f.path)[1].lower()
        for pat in DENY_PATH_PATTERNS:
            if re.search(pat, f.path):
                reasons.append("denylist パス: %s (pattern: %s)" % (f.path, pat))
                break
        if f.binary:
            reasons.append("バイナリ変更: %s" % f.path)
            continue
        if f.new_file or f.deleted or f.renamed:
            reasons.append("新規/削除/rename を含む: %s" % f.path)
        for minus, plus in f.hunks:
            total_lines += len(minus) + len(plus)
        if ext in DOC_EXTS:
            continue
        if ext not in CODE_EXTS:
            reasons.append("対象外拡張子: %s" % f.path)
            continue
        for minus, plus in f.hunks:
            if len(minus) != len(plus):
                reasons.append(
                    "%s: 行の増減あり（-%d/+%d）＝構造変更の可能性" % (f.path, len(minus), len(plus))
                )
                continue
            for old, new in zip(minus, plus):
                why = _check_pair(old, new, ext)
                if why:
                    reasons.append("%s: %s" % (f.path, why))

    if total_lines > MAX_CHANGED_LINES:
        reasons.append("変更行数 %d > 上限 %d" % (total_lines, MAX_CHANGED_LINES))

    if reasons:
        return False, "\n".join("- " + r for r in reasons)
    return True, "%d ファイル / %d 行、文言修正程度と判定" % (len(files), total_lines)


def main():
    ap = argparse.ArgumentParser(description="文言修正ゲート")
    ap.add_argument("--stdin", action="store_true", help="stdin から diff を読む")
    ap.add_argument("--diff-file", help="diff ファイルパス")
    ap.add_argument("--pr", help="PR 番号（gh pr diff で取得）")
    ap.add_argument("--repo", help="owner/repo（--pr と併用）")
    args = ap.parse_args()

    try:
        if args.pr:
            if not args.repo:
                print("[wording-fix-gate] NG: --pr には --repo が必須", file=sys.stderr)
                sys.exit(1)
            r = subprocess.run(
                ["gh", "pr", "diff", str(args.pr), "--repo", args.repo],
                capture_output=True, text=True, timeout=60,
            )
            if r.returncode != 0:
                print("[wording-fix-gate] NG: gh pr diff 失敗: %s" % r.stderr.strip()[-300:], file=sys.stderr)
                sys.exit(1)
            diff_text = r.stdout
        elif args.diff_file:
            with open(args.diff_file, "r", encoding="utf-8", errors="replace") as fp:
                diff_text = fp.read()
        else:
            diff_text = sys.stdin.read()
        ok, report = evaluate(diff_text)
    except Exception as e:  # fail-closed
        print("[wording-fix-gate] NG: 判定中に例外 (%s: %s)" % (type(e).__name__, e), file=sys.stderr)
        sys.exit(1)

    if ok:
        print("[wording-fix-gate] PASS: %s" % report)
        sys.exit(0)
    print("[wording-fix-gate] NG: 文言修正程度と判定できない\n%s" % report, file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()

