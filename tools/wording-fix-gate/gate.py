#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""wording-fix-gate: unified diff が「文言修正程度」かを機械判定する (fail-closed)。

「文言修正程度」の定義（すべて満たすこと）:
  - 変更ファイル数 <= maxFiles / 変更行数(+/-合計) <= maxChangedLines（既定 5 / 80）
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

閾値と denylist は `.claude/devkit.json` の `wordingGate` セクションで差し替える
（柱4「プロジェクト固有値は 1 箇所に集約する」）:

    "wordingGate": { "maxFiles": 5, "maxChangedLines": 80, "extraDeny": ["^config/secrets/"] }

設定ファイルが**壊れている場合は fail-closed**（既定値へ黙って落ちない）。
環境変数 WORDING_GATE_EXTRA_DENY（`:` 区切りの正規表現）でも足せる。両方指定すれば両方効く。
WORDING_GATE_CONFIG で設定ファイルのパスを明示できる（テスト用）。

使い方:
  git diff origin/<base>...HEAD | python3 .claude/devkit/wording-fix-gate/gate.py --stdin
  python3 .claude/devkit/wording-fix-gate/gate.py --pr 123 --repo owner/repo
"""

import argparse
import json
import os
import re
import subprocess
import sys

DEFAULT_MAX_FILES = 5
DEFAULT_MAX_CHANGED_LINES = 80

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


class ConfigError(Exception):
    """設定を読めない/壊れている。判定不能なので fail-closed に倒す。"""


def _config_path():
    """.claude/devkit.json の在り処。無ければ None（＝既定値で動く）。"""
    override = os.environ.get("WORDING_GATE_CONFIG", "").strip()
    if override:
        return override if os.path.exists(override) else None
    root = ""
    try:
        r = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode == 0:
            root = r.stdout.strip()
    except Exception:
        root = ""
    path = os.path.join(root or ".", ".claude", "devkit.json")
    return path if os.path.exists(path) else None


def load_config():
    """(max_files, max_changed_lines, deny_patterns) を返す。

    設定ファイルが在るのに読めない・型が違う場合は ConfigError。
    「壊れた設定を既定値で黙って読み替える」と、denylist を足したつもりの
    プロジェクトが素通しになるため、fail-closed にする。
    """
    max_files = DEFAULT_MAX_FILES
    max_lines = DEFAULT_MAX_CHANGED_LINES
    deny = list(DENY_PATH_PATTERNS)

    path = _config_path()
    if path:
        try:
            with open(path, "r", encoding="utf-8") as fp:
                cfg = json.load(fp)
        except Exception as e:
            raise ConfigError("%s を読めない (%s: %s)" % (path, type(e).__name__, e))
        section = cfg.get("wordingGate") or {}
        if not isinstance(section, dict):
            raise ConfigError("%s: wordingGate はオブジェクトである必要がある" % path)
        if section.get("maxFiles") is not None:
            max_files = _positive_int(section["maxFiles"], "wordingGate.maxFiles", path)
        if section.get("maxChangedLines") is not None:
            max_lines = _positive_int(section["maxChangedLines"], "wordingGate.maxChangedLines", path)
        extra = section.get("extraDeny") or []
        if not isinstance(extra, list):
            raise ConfigError("%s: wordingGate.extraDeny は配列である必要がある" % path)
        deny += [str(x) for x in extra if str(x)]

    env_extra = os.environ.get("WORDING_GATE_EXTRA_DENY", "").strip()
    if env_extra:
        deny += [p for p in env_extra.split(":") if p]

    # 不正な正規表現は「判定不能」。ここで弾かないと re.search が例外を投げ、
    # denylist の残りが評価されないまま別の理由で落ちて原因が分からなくなる。
    for pat in deny:
        try:
            re.compile(pat)
        except re.error as e:
            raise ConfigError("denylist の正規表現が不正: %r (%s)" % (pat, e))
    return max_files, max_lines, deny


def _positive_int(value, label, path):
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ConfigError("%s: %s は正の整数である必要がある (%r)" % (path, label, value))
    return value


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
    max_files, max_changed_lines, deny_patterns = load_config()
    reasons = []
    if not diff_text or not diff_text.strip():
        return False, "diff が空（取得失敗 or 差分なし）"

    files = parse_diff(diff_text)
    if not files:
        return False, "diff を解析できない（unified diff 形式でない）"

    if len(files) > max_files:
        reasons.append("変更ファイル数 %d > 上限 %d" % (len(files), max_files))

    total_lines = 0
    for f in files:
        ext = os.path.splitext(f.path)[1].lower()
        for pat in deny_patterns:
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

    if total_lines > max_changed_lines:
        reasons.append("変更行数 %d > 上限 %d" % (total_lines, max_changed_lines))

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

