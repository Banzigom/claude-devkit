#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PreToolUse(Bash) hook: PR マージコマンドを文言修正ゲートで機械判定する。

Claude が実行する `gh pr merge` / REST merge (`pulls/N/merge`) / GraphQL
`mergePullRequest` を検知し、対象 PR の diff が gate.py に合格した場合のみ許可。
非合格・判定不能はすべて exit 2 で block（fail-closed）し、ユーザーの手動マージへ誘導する。

このゲートは「Claude のツール呼び出し」にのみ効く。ユーザー自身のターミナル実行は
対象外なので、非文言修正 PR のマージはユーザーが手動で行う運用。
"""

import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate  # noqa: E402

# コマンド位置（行頭 / ; & | の後 / $( の後、env 変数プレフィクス許容）に現れた
# マージ実行のみ検知する。heredoc / echo 等の本文中に "gh pr merge" が
# 文字列として含まれるだけのケース（issue 本文・ドキュメント記述）には反応しない。
_ANCHOR = r"(?m)(?:^|[;&|]\s*|\$\(\s*)\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*"
MERGE_PATTERNS = [
    _ANCHOR + r"(?:command\s+)?gh\s+pr\s+merge\b",
    r"gh\s+api\b[^\n]*pulls/\d+/merge",
    r"api\.github\.com/[^\s'\"]*pulls/\d+/merge",
    r"gh\s+api\b[\s\S]*mergePullRequest",
]

BLOCK_HEADER = "[wording-fix-gate] PR マージをブロック（文言修正ゲート）\n"
BLOCK_FOOTER = (
    "\n非文言修正 PR のマージは Claude からは実行不可。"
    "ユーザーに実行コマンドを提示して手動マージを依頼すること。"
    "詳細: .claude/devkit/wording-fix-gate/README.md"
)


def block(msg):
    sys.stderr.write(BLOCK_HEADER + msg + BLOCK_FOOTER)
    sys.exit(2)


def resolve_target(cmd):
    """コマンド文字列から (repo, pr_number) を解決する。解決不能なら block。"""
    m = re.search(r"repos/([\w.-]+)/([\w.-]+)/pulls/(\d+)/merge", cmd)
    if m:
        return "%s/%s" % (m.group(1), m.group(2)), m.group(3)

    if re.search(r"mergePullRequest", cmd):
        block(
            "GraphQL mergePullRequest は PR を特定できないため常にブロック。"
            "`gh pr merge <番号> --repo <owner/repo> --merge` 形式を使うこと。"
        )

    # gh pr merge <URL>
    m = re.search(r"gh\s+pr\s+merge\s+\"?(?:https://github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+))", cmd)
    if m:
        return "%s/%s" % (m.group(1), m.group(2)), m.group(3)

    # gh pr merge <number> ... --repo/-R owner/repo
    m = re.search(r"gh\s+pr\s+merge\s+(\d+)\b", cmd)
    num = m.group(1) if m else None
    m = re.search(r"(?:--repo|-R)[=\s]+\"?([\w.-]+/[\w.-]+)", cmd)
    repo = m.group(1) if m else None
    if num and repo:
        return repo, num

    block(
        "PR を特定できない（番号 or repo が不明）。"
        "`gh pr merge <番号> --repo <owner/repo> --merge` の形式で再実行すること。"
    )


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)  # hook 入力が不正 → 判定対象外
    if data.get("tool_name") != "Bash":
        sys.exit(0)
    cmd = (data.get("tool_input") or {}).get("command") or ""
    if not any(re.search(p, cmd) for p in MERGE_PATTERNS):
        sys.exit(0)

    # ここから先はマージ試行 → fail-closed
    repo, num = resolve_target(cmd)
    try:
        r = subprocess.run(
            ["gh", "pr", "diff", num, "--repo", repo],
            capture_output=True, text=True, timeout=60,
        )
    except Exception as e:
        block("gh pr diff 実行に失敗 (%s: %s)" % (type(e).__name__, e))
    if r.returncode != 0 or not r.stdout.strip():
        block(
            "PR diff を取得できない (%s#%s)。gh auth（アカウント切替）と PR 番号を確認。\n%s"
            % (repo, num, (r.stderr or "").strip()[-300:])
        )

    try:
        ok, report = gate.evaluate(r.stdout)
    except Exception as e:
        block("ゲート判定中に例外 (%s: %s)" % (type(e).__name__, e))

    if ok:
        print("[wording-fix-gate] PASS (%s#%s): %s" % (repo, num, report))
        sys.exit(0)
    block("%s#%s は文言修正程度と判定できない:\n%s" % (repo, num, report))


if __name__ == "__main__":
    main()
