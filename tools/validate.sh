#!/usr/bin/env bash
#
# validate.sh — claude-devkit 自身の健全性を検証する
#
# devkit を編集したら必ず実行する。検証内容:
#   1. 抽出元プロジェクト固有語の残留がないか（汎用性の担保）
#   2. JSON が妥当か
#   3. skill / agent の frontmatter（name / description、name とパスの一致）
#   4. 相対リンクが解決するか
#   5. シェルスクリプトの構文
#   6. 設定読み込みが exit code を落とさない形になっているか
#
# この検証自身も故意破壊で確かめること（templates/rules/README.md §検証自身の検証）。

set -uo pipefail
cd "$(dirname "$0")/.."

FAILED=0
fail() { echo "  ❌ $1"; FAILED=1; }
pass() { echo "  ✅ $1"; }

# 抽出元の固有語。devkit を別プロジェクトから育てる場合はここに足す。
FORBIDDEN='takaiba|ti-frontend-t3|ti-backend-ml|ti-chatgpt-proxy|ti-terraform|ti-project|qt-genai|QT-GenAI|PVT_kwDOB|PVTSSF_lADOB'

echo "[1/6] 固有語の残留"
# 自分自身（パターン定義を含む）は走査対象から外す。外さないと常に自己ヒットする。
if hits=$(grep -rniE "$FORBIDDEN" --include='*.md' --include='*.json' --include='*.sh' \
            --exclude='validate.sh' . 2>/dev/null); then
  fail "固有語が残っている:"; echo "$hits" | sed 's/^/       /'
else
  pass "残留なし"
fi

echo "[2/6] JSON 妥当性"
json_ng=0
for f in .claude-plugin/*.json templates/*.json; do
  [ -e "$f" ] || continue
  jq -e . "$f" >/dev/null 2>&1 || { fail "不正な JSON: $f"; json_ng=1; }
done
[ "$json_ng" -eq 0 ] && pass "全 JSON が妥当"

echo "[3/6] frontmatter"
python3 - <<'PY' || FAILED=1
import glob,os,re,sys
ng=0
def fm(path):
    s=open(path,encoding='utf-8').read()
    if not s.startswith('---\n'): return None
    end=s.find('\n---\n',3)
    if end<0: return None
    d={}
    for line in s[4:end].split('\n'):
        m=re.match(r'^([a-zA-Z-]+):\s*(.*)$',line)
        if m: d[m.group(1)]=m.group(2)
    return d
for p in sorted(glob.glob('skills/*/SKILL.md')):
    d=fm(p); dirn=os.path.basename(os.path.dirname(p))
    if d is None or d.get('name')!=dirn or not d.get('description'):
        print(f"  ❌ skill frontmatter 不正: {p}"); ng+=1
for p in sorted(glob.glob('agents/*.md')):
    d=fm(p); base=os.path.basename(p)[:-3]
    if d is None or d.get('name')!=base or not d.get('description'):
        print(f"  ❌ agent frontmatter 不正: {p}"); ng+=1
if ng==0: print(f"  ✅ skill {len(glob.glob('skills/*/SKILL.md'))} 件 / agent {len(glob.glob('agents/*.md'))} 件")
sys.exit(1 if ng else 0)
PY

echo "[4/6] 相対リンク解決"
python3 - <<'PY' || FAILED=1
import glob,os,re,sys
bad=[]; n=0
fence=re.compile(r'^````*')
for p in glob.glob('**/*.md',recursive=True):
    if '/.git/' in p: continue
    infence=False
    for line in open(p,encoding='utf-8'):
        if fence.match(line): infence=not infence; continue
        if infence: continue
        line=re.sub(r'`[^`]*`','',line)
        for m in re.finditer(r'\]\(([^)]+)\)',line):
            t=m.group(1)
            if re.match(r'^(https?:|mailto:|#)',t): continue
            t=t.split('#')[0]
            if not t or '...' in t: continue
            n+=1
            if not os.path.exists(os.path.join(os.path.dirname(p),t)): bad.append((p,t))
for f,t in bad: print(f"  ❌ {f} -> {t}")
if not bad: print(f"  ✅ 相対リンク {n} 件すべて解決")
sys.exit(1 if bad else 0)
PY

echo "[5/6] シェル構文"
sh_ng=0
for f in tools/*.sh; do bash -n "$f" 2>/dev/null || { fail "構文エラー: $f"; sh_ng=1; }; done
[ "$sh_ng" -eq 0 ] && pass "tools/*.sh すべて構文 OK"

echo "[6/6] 設定読み込みの形"
# eval "$(bash config.sh)" の 1 行形はコマンド置換の exit code を落とすので禁止
if grep -rn 'eval "\$(bash .claude/devkit/config.sh)"' skills/ agents/ 2>/dev/null; then
  fail "exit code を落とす 1 行形が残っている（DEVKIT_ENV へ受けてから eval する）"
else
  pass "DEVKIT_ENV 経由に統一"
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "validate: PASS"; else echo "validate: FAIL"; fi
exit "$FAILED"
