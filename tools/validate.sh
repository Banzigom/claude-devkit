#!/usr/bin/env bash
#
# validate.sh — claude-devkit 自身の健全性を検証する
#
# devkit を編集したら必ず実行する。検証内容:
#   1. JSON が妥当か / プラグインのバージョン表記が 3 箇所で一致するか
#   2. skill / agent の frontmatter（name / description、name とパスの一致、agent の model）
#   3. 相対リンクが解決するか
#   4. シェルスクリプトの構文
#   5. Python の構文と wording-fix-gate のゴールデンテスト
#   6. 設定読み込みが exit code を落とさない形／cwd に依存しない形になっているか
#   7. skill が参照する tools/ のファイルが実在するか（devkit-init のコピー漏れ検出）
#   8. skill が参照する設定キー・変数が実在するか / config.sh の既定値がテンプレと一致するか
#
# この検証自身も故意破壊で確かめること（templates/rules/README.md §検証自身の検証）。
#
# 🔴 検証を足したら **FAILED を立てる経路まで** 作ること。ローカル変数だけ立てて
#    FAILED に伝えないと、❌ を表示しながら exit 0 で通る（検証 4 に実際そのバグがあった）。
#    「違反を 1 件仕込んで exit 1 になる」ところまで実測して初めて検証を足したことになる。

set -uo pipefail
cd "$(dirname "$0")/.."

FAILED=0
fail() { echo "  ❌ $1"; FAILED=1; }
pass() { echo "  ✅ $1"; }

echo "[1/8] JSON 妥当性 / バージョン整合"
json_ng=0
for f in .claude-plugin/*.json templates/*.json; do
  [ -e "$f" ] || continue
  jq -e . "$f" >/dev/null 2>&1 || { fail "不正な JSON: $f"; json_ng=1; }
done
if [ "$json_ng" -eq 0 ]; then
  # バージョンは plugin.json / marketplace.json の 3 箇所に散っている。ずれると
  # 「どれが入っているのか」が分からなくなり、devkit-update の判断材料も壊れる。
  v_plugin=$(jq -r '.version' .claude-plugin/plugin.json)
  v_mk_meta=$(jq -r '.metadata.version' .claude-plugin/marketplace.json)
  v_mk_entry=$(jq -r '.plugins[0].version' .claude-plugin/marketplace.json)
  if [ "$v_plugin" = "$v_mk_meta" ] && [ "$v_plugin" = "$v_mk_entry" ]; then
    pass "全 JSON が妥当 / version=${v_plugin} が 3 箇所で一致"
  else
    fail "version 不一致: plugin.json=${v_plugin} / marketplace.metadata=${v_mk_meta} / marketplace.plugins[0]=${v_mk_entry}"
  fi
fi

echo "[2/8] frontmatter"
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
        continue
    # model を書き忘れた agent は親セッションのモデルを引き継ぐ。レビュー系を
    # 意図せず高コストなモデルで回す事故になるので、明示を必須にする。
    if not d.get('model'):
        print(f"  ❌ agent に model 指定が無い: {p}"); ng+=1

# 破壊的 CLI の丸ごと許可を禁じる。`Bash(gcloud *)` は
# `gcloud sql instances delete` まで無確認で通してしまい、本文で 🔴 と書いた
# 制約が機械層でまったく効かない（local-destroy が「git restore 禁止」と書きながら
# Bash(git *) を許可していた）。動詞まで絞るか、許可リストに載せず都度承認に倒す。
# git は開発ハーネスの本体なので対象外（commit / branch は skill 本文の人のゲートで守る）。
# ここで止めたいのは「本番環境を無確認で壊せる」CLI の丸ごと許可。
DESTRUCTIVE=('gcloud','aws','az','docker','kubectl','terraform','helm','psql','mysql','rm','sudo')
WILDCARD=re.compile(r'Bash\((%s) \*\)' % '|'.join(DESTRUCTIVE))
for p in sorted(glob.glob('skills/*/SKILL.md')+glob.glob('agents/*.md')):
    d=fm(p) or {}
    for key in ('allowed-tools','tools'):
        for m in WILDCARD.finditer(d.get(key,'')):
            print(f"  ❌ 破壊的 CLI の丸ごと許可: {p} の {key} に {m.group(0)}"
                  f"（動詞まで絞るか、許可リストから外して都度承認にする）"); ng+=1
if ng==0: print(f"  ✅ skill {len(glob.glob('skills/*/SKILL.md'))} 件 / agent {len(glob.glob('agents/*.md'))} 件")
sys.exit(1 if ng else 0)
PY

echo "[3/8] 相対リンク解決"
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

echo "[4/8] シェル構文"
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
if [ "$sh_ng" -eq 0 ]; then
  pass "tools/*.sh すべて構文 OK / マルチバイト隣接なし"
else
  FAILED=1
fi

echo "[5/8] Python 構文 / wording-fix-gate ゴールデンテスト"
py_ng=0
# py_compile は __pycache__ を書くので compile() で in-memory に済ませる。
for f in $(find tools -name '*.py' | sort); do
  python3 -c 'import sys;compile(open(sys.argv[1],encoding="utf-8").read(),sys.argv[1],"exec")' "$f" 2>/dev/null \
    || { fail "Python 構文エラー: $f"; py_ng=1; }
done
# 分類器は「本当に落ちるか」を実測して初めて検証したことになる。PASS するだけの
# 検証は「そもそも見ていない」と区別が付かないので、通るべき diff と落ちるべき
# diff の両方を固定して回す（tests/wording-fix-gate/）。
python3 - <<'GATE' || py_ng=1
import glob,os,subprocess,sys
GATE_PY='tools/wording-fix-gate/gate.py'
ROOT='tests/wording-fix-gate'
bad=[]; n=0

def run(diff, config=None):
    env=dict(os.environ)
    env.pop('WORDING_GATE_EXTRA_DENY', None)
    if config: env['WORDING_GATE_CONFIG']=config
    else: env['WORDING_GATE_CONFIG']=''
    r=subprocess.run([sys.executable,GATE_PY,'--diff-file',diff],
                     capture_output=True,text=True,env=env)
    return r.returncode

for d in sorted(glob.glob(ROOT+'/pass/*.diff')):
    n+=1
    if run(d)!=0: bad.append("%s は PASS すべきだが NG" % d)
for d in sorted(glob.glob(ROOT+'/ng/*.diff')):
    n+=1
    if run(d)==0: bad.append("%s は NG すべきだが PASS" % d)

# 設定ケースは「設定を渡したときの結果」と「渡さなかったときの結果」が
# 逆であることまで確かめる。片方だけだと、設定が読まれていなくても通ってしまう。
for kind,want,want_default in (('config-pass',0,1),('config-ng',1,0)):
    for cfg in sorted(glob.glob('%s/%s/*.json' % (ROOT,kind))):
        diff=cfg[:-5]+'.diff'
        if not os.path.exists(diff):
            bad.append("%s に対応する .diff が無い" % cfg); continue
        n+=1
        if run(diff,cfg)!=want:
            bad.append("%s: 設定ありの結果が期待と違う（期待 exit %d）" % (cfg,want))
        if run(diff)!=want_default:
            bad.append("%s: 設定なしの結果が期待と違う（期待 exit %d）＝設定が効いていない" % (cfg,want_default))

for b in bad: print("  ❌ "+b)
if not bad: print("  ✅ ゴールデンテスト %d ケースすべて期待どおり" % n)
sys.exit(1 if bad else 0)
GATE
if [ "$py_ng" -eq 0 ]; then
  pass "tools/**/*.py すべて構文 OK"
else
  FAILED=1
fi

echo "[6/8] 設定読み込みの形"
python3 - <<'CHK6' || FAILED=1
import glob,re,sys
# (a) eval "$(bash config.sh)" の 1 行形はコマンド置換の exit code を落とすので禁止。
# (b) cwd がリポジトリルートである前提の相対パス起動も禁止。サブディレクトリで
#     セッションが始まっただけで「設定が無い」と誤判定して skill が止まる。
#     config.sh は git rev-parse で、それ以降は $DEVKIT_ROOT で絶対化する。
#     `(?<![\w.])` が無いと "…fetch.sh .claude/devkit/…" の末尾 sh に誤反応する。
ONELINE=re.compile(r'eval "\$\(bash [^"]*config\.sh\)"')
RELATIVE=re.compile(r'(?<![\w.])(bash|sh|python3) \.claude/devkit/')
bad=[]
for p in sorted(glob.glob('skills/*/SKILL.md')+glob.glob('agents/*.md')):
    for i,line in enumerate(open(p,encoding='utf-8'),1):
        if ONELINE.search(line):
            bad.append("%s:%d exit code を落とす 1 行形（DEVKIT_ENV へ受けてから eval する）" % (p,i))
        if RELATIVE.search(line):
            bad.append('%s:%d cwd 依存の相対パス起動（config.sh は "$(git rev-parse --show-toplevel)/..."、以降は "$DEVKIT_ROOT/..."）' % (p,i))
for b in bad: print("  ❌ "+b)
if not bad: print("  ✅ DEVKIT_ENV 経由 / cwd 非依存に統一")
sys.exit(1 if bad else 0)
CHK6

echo "[7/8] skill が参照する tools/ の実在"
python3 - <<'CHK7' || FAILED=1
import glob,os,re,sys
# skill / agent 本文の `.claude/devkit/<name>` 参照が tools/ に実体を持つか。
# 参照だけ増やして devkit-init のコピー対象に入れ忘れる事故を検出する。
# GENERATED は devkit-init が生成するもの（プラグイン側に実体を持たない）。
GENERATED={'VERSION'}
refs=set()
for p in glob.glob('skills/*/SKILL.md')+glob.glob('agents/*.md'):
    for m in re.finditer(r'\.claude/devkit/([A-Za-z0-9_./-]+)', open(p,encoding='utf-8').read()):
        refs.add(m.group(1))
missing=[]
for r in sorted(refs):
    if r in GENERATED: continue
    top=r.split('/')[0]
    if not (os.path.exists(os.path.join('tools',r)) or os.path.isdir(os.path.join('tools',top))):
        missing.append(r)
for r in missing: print("  ❌ tools/ に実体が無い参照: .claude/devkit/%s" % r)
if not missing: print("  ✅ 参照 %d 件すべて tools/ に実在" % len(refs))
sys.exit(1 if missing else 0)
CHK7

echo "[8/8] 設定キー・変数・既定値の整合"
python3 - <<'CHK8' || FAILED=1
import glob,json,re,sys
# $DEVKIT_* が config.sh の export に実在するか / jq で引く設定キーがテンプレに実在するか /
# config.sh が emit するパスが全部入りテンプレに実在するか / 既定値がテンプレと食い違わないか。
cfg=open('tools/config.sh',encoding='utf-8').read()
exported=set(re.findall(r'emit\s+(DEVKIT_[A-Z0-9_]+)',cfg)) | set(re.findall(r'export (DEVKIT_[A-Z0-9_]+)=',cfg))
LOCAL={'DEVKIT_ENV'}   # skill 側でローカルに作る変数
used=set()
for p in glob.glob('skills/*/SKILL.md')+glob.glob('agents/*.md'):
    used |= set(re.findall(r'\$\{?(DEVKIT_[A-Z0-9_]+)',open(p,encoding='utf-8').read()))
unknown=sorted(used - exported - LOCAL)
for v in unknown: print("  ❌ config.sh が export していない変数を参照: $%s" % v)

def load(path): return json.load(open(path,encoding='utf-8'))
tpl=load('templates/devkit.json')
full=load('templates/devkit.full-example.json')

def get(d,path,miss=KeyError):
    cur=d
    for part in path.split('.'):
        if not isinstance(cur,dict) or part not in cur: return miss
        cur=cur[part]
    return cur

paths=set()
SECTIONS='tracker|schedule|report|infra|database|rules|review|verify|wordingGate'
for p in glob.glob('skills/*/SKILL.md'):
    for line in open(p,encoding='utf-8').read().split('\n'):
        if 'DEVKIT_CONFIG' not in line or 'jq' not in line: continue
        for k in re.findall(r'\.((?:%s)(?:\.[A-Za-z]+)*)' % SECTIONS, line):
            paths.add(k)
badkeys=sorted(k for k in paths if get(tpl,k) is KeyError)
for k in badkeys: print("  ❌ templates/devkit.json に無いキーを参照: .%s" % k)

# config.sh の emit パスは「全部入りテンプレ」が網羅していること。
# 最小テンプレは意図的に一部を持たないが、全部入りに無いキーは設定手段が
# どこにも書かれていないことになり、埋めようがない。
emits=[m.group(1) for m in re.finditer(r"emit\s+DEVKIT_[A-Z0-9_]+\s+'\.([A-Za-z0-9_.]+)'",cfg)]
notdoc=sorted(p for p in emits if get(full,p) is KeyError)
for p in notdoc: print("  ❌ devkit.full-example.json に無いキーを emit している: .%s" % p)

# emit の第 3 引数（既定値）とテンプレの値が食い違うと、キーを書いた場合と
# 省いた場合で挙動が変わる。commitLanguage が実際にずれていた。
drift=[]
for m in re.finditer(r"emit\s+DEVKIT_[A-Z0-9_]+\s+'\.([A-Za-z0-9_.]+)'\s+'([^']*)'",cfg):
    path,default=m.group(1),m.group(2)
    v=get(tpl,path)
    if v is KeyError or v is None: continue
    if str(v)!=default:
        drift.append((path,default,v))
for path,default,v in drift:
    print("  ❌ config.sh の既定値とテンプレの値が不一致: .%s (config.sh=%r / devkit.json=%r)" % (path,default,v))

ok = not (unknown or badkeys or notdoc or drift)
if ok:
    print("  ✅ 変数 %d 種 / 参照キー %d 種 / emit %d 種すべて整合" % (len(used),len(paths),len(emits)))
sys.exit(0 if ok else 1)
CHK8

echo
if [ "$FAILED" -eq 0 ]; then echo "validate: PASS"; else echo "validate: FAIL"; fi
exit "$FAILED"
