#!/usr/bin/env bash
#
# validate.sh — claude-devkit 自身の健全性を検証する
#
# devkit を編集したら必ず実行する。検証内容:
#   1. JSON が妥当か
#   2. skill / agent の frontmatter（name / description、name とパスの一致）
#   3. 相対リンクが解決するか
#   4. シェルスクリプトの構文
#   5. 設定読み込みが exit code を落とさない形になっているか
#   6. skill が参照する tools/ のファイルが実在するか（devkit-init のコピー漏れ検出）
#   7. skill が参照する設定キー・変数が実在するか
#
# この検証自身も故意破壊で確かめること（templates/rules/README.md §検証自身の検証）。

set -uo pipefail
cd "$(dirname "$0")/.."

FAILED=0
fail() { echo "  ❌ $1"; FAILED=1; }
pass() { echo "  ✅ $1"; }

echo "[1/7] JSON 妥当性"
json_ng=0
for f in .claude-plugin/*.json templates/*.json; do
  [ -e "$f" ] || continue
  jq -e . "$f" >/dev/null 2>&1 || { fail "不正な JSON: $f"; json_ng=1; }
done
[ "$json_ng" -eq 0 ] && pass "全 JSON が妥当"

echo "[2/7] frontmatter"
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

echo "[3/7] 相対リンク解決"
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

echo "[4/7] シェル構文"
sh_ng=0
for f in tools/*.sh; do bash -n "$f" 2>/dev/null || { fail "構文エラー: $f"; sh_ng=1; }; done

# 🔴 $VAR の直後にマルチバイト文字が来ると、bash はそれを変数名の一部として読む。
#    `set -u` の下では unbound variable になり、**意図した exit code もメッセージも失われる**
#    （実際 rules-size-check.sh のセットアップ不備メッセージが exit 2 でなく exit 1 で無言死していた）。
#    日本語メッセージの中では ${VAR} のブレースを必須にする。
#    判定は python で行う。POSIX ERE の [^\x00-\x7F] はバイト範囲として解釈されず誤検知する。
python3 - <<'MBCHK' || sh_ng=1
import glob,re,sys
pat=re.compile(r'\$[A-Za-z_][A-Za-z0-9_]*(?=[^\x00-\x7f])')
bad=[]
for f in sorted(glob.glob('tools/*.sh')):
    for i,line in enumerate(open(f,encoding='utf-8'),1):
        for m in pat.finditer(line):
            bad.append(f"{f}:{i}: {m.group(0)}{line[m.end():m.end()+1]}")
for b in bad: print("  ❌ $VAR の直後にマルチバイト文字（${VAR} のブレースが必要）: "+b)
sys.exit(1 if bad else 0)
MBCHK
[ "$sh_ng" -eq 0 ] && pass "tools/*.sh すべて構文 OK / マルチバイト隣接なし"

echo "[5/7] 設定読み込みの形"
# eval "$(bash config.sh)" の 1 行形はコマンド置換の exit code を落とすので禁止
if grep -rn 'eval "\$(bash .claude/devkit/config.sh)"' skills/ agents/ 2>/dev/null; then
  fail "exit code を落とす 1 行形が残っている（DEVKIT_ENV へ受けてから eval する）"
else
  pass "DEVKIT_ENV 経由に統一"
fi

echo "[6/7] skill が参照する tools/ の実在"
python3 - <<'CHK7' || FAILED=1
import glob,os,re,sys
# skill / agent 本文の `.claude/devkit/<name>` 参照が tools/ に実体を持つか。
# 参照だけ増やして devkit-init のコピー対象に入れ忘れる事故を検出する。
refs=set()
for p in glob.glob('skills/*/SKILL.md')+glob.glob('agents/*.md'):
    for m in re.finditer(r'\.claude/devkit/([A-Za-z0-9_./-]+)', open(p,encoding='utf-8').read()):
        refs.add(m.group(1))
missing=[]
for r in sorted(refs):
    top=r.split('/')[0]
    if not (os.path.exists(os.path.join('tools',r)) or os.path.isdir(os.path.join('tools',top))):
        missing.append(r)
for r in missing: print("  ❌ tools/ に実体が無い参照: .claude/devkit/%s" % r)
if not missing: print("  ✅ 参照 %d 件すべて tools/ に実在" % len(refs))
sys.exit(1 if missing else 0)
CHK7

echo "[7/7] skill が参照する設定キー・変数の実在"
python3 - <<'CHK8' || FAILED=1
import glob,json,re,sys
# $DEVKIT_* が config.sh の export に実在するか / jq で引く設定キーがテンプレに実在するか。
cfg=open('tools/config.sh',encoding='utf-8').read()
exported=set(re.findall(r'emit\s+(DEVKIT_[A-Z0-9_]+)',cfg)) | set(re.findall(r'export (DEVKIT_[A-Z0-9_]+)=',cfg))
LOCAL={'DEVKIT_ENV'}   # skill 側でローカルに作る変数
used=set()
for p in glob.glob('skills/*/SKILL.md')+glob.glob('agents/*.md'):
    used |= set(re.findall(r'\$\{?(DEVKIT_[A-Z0-9_]+)',open(p,encoding='utf-8').read()))
unknown=sorted(used - exported - LOCAL)
for v in unknown: print("  ❌ config.sh が export していない変数を参照: $%s" % v)

tpl=json.load(open('templates/devkit.json',encoding='utf-8'))
def haskey(d,path):
    cur=d
    for part in path.split('.'):
        if not isinstance(cur,dict) or part not in cur: return False
        cur=cur[part]
    return True
paths=set()
SECTIONS='tracker|schedule|report|infra|database|rules|review|verify'
for p in glob.glob('skills/*/SKILL.md'):
    for line in open(p,encoding='utf-8').read().split('\n'):
        if 'DEVKIT_CONFIG' not in line or 'jq' not in line: continue
        for k in re.findall(r'\.((?:%s)(?:\.[A-Za-z]+)*)' % SECTIONS, line):
            paths.add(k)
badkeys=sorted(k for k in paths if not haskey(tpl,k))
for k in badkeys: print("  ❌ templates/devkit.json に無いキーを参照: .%s" % k)
if not unknown and not badkeys:
    print("  ✅ 変数 %d 種 / 設定キー %d 種すべて実在" % (len(used), len(paths)))
sys.exit(1 if (unknown or badkeys) else 0)
CHK8

echo
if [ "$FAILED" -eq 0 ]; then echo "validate: PASS"; else echo "validate: FAIL"; fi
exit "$FAILED"

