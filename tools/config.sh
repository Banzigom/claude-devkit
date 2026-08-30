#!/usr/bin/env bash
#
# config.sh — .claude/devkit.json を読んで shell 変数として export する
#
# 使い方（skill / スクリプトから）:
#   DEVKIT_ENV=$(bash .claude/devkit/config.sh) || exit 1
#   eval "$DEVKIT_ENV"
#
# `eval "$(bash config.sh)"` と 1 行で書かないこと。コマンド置換の exit code は
# eval に伝わらないため、設定不備で exit 1 しても呼び出し側は成功として進んでしまう
# （空の出力を eval すると 0 が返る）。必ず一度変数へ受けて exit code を見る。
#
# bash 3.2 (macOS 同梱) 互換で書く。連想配列・${!arr[@]} は使わない。

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
CFG="$ROOT/.claude/devkit.json"

if [ ! -f "$CFG" ]; then
  echo "ERROR: $CFG が存在しない。/devkit-init を先に実行すること。" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq が必要（brew install jq）。" >&2
  exit 1
fi

if ! jq -e . "$CFG" >/dev/null 2>&1; then
  echo "ERROR: $CFG が不正な JSON。" >&2
  exit 1
fi

# 必須項目の検証は「export を 1 行も出す前」に済ませる。
# 途中まで出してから exit すると、呼び出し側が部分的な設定を eval しうる。
REPO_VAL=$(jq -r '.repo // empty' "$CFG")
if [ -z "$REPO_VAL" ]; then
  echo "ERROR: .repo が未設定。OWNER/REPO 形式で書くこと。" >&2
  exit 1
fi

# jq の出力を shell の代入文として安全に出す。
# null / 未設定は空文字にする（呼び出し側は [ -n "$VAR" ] で未設定を判定する）。
emit() { # emit <VAR_NAME> <jq_path> [default]
  local name="$1" path="$2" def="${3:-}"
  local val
  val=$(jq -r "$path // empty" "$CFG")
  [ -z "$val" ] && val="$def"
  printf 'export %s=%s\n' "$name" "$(printf '%q' "$val")"
}

printf 'export DEVKIT_ROOT=%s\n' "$(printf '%q' "$ROOT")"
# 配列（siblingRepos）は bash 3.2 では素直に export できないので、設定ファイルの
# パスだけ渡して呼び出し側が jq で読む:
#   jq -r '.siblingRepos[] | "\(.name)\t\(.path)\t\(.repo // "")"' "$DEVKIT_CONFIG"
printf 'export DEVKIT_CONFIG=%s\n' "$(printf '%q' "$CFG")"
emit DEVKIT_REPO              '.repo'
emit DEVKIT_BASE_BRANCH       '.baseBranch' 'main'
emit DEVKIT_BRANCH_PREFIX     '.branchPrefix' 'feature/'
emit DEVKIT_COMMIT_LANG       '.commitLanguage' 'ja'

emit DEVKIT_CMD_LINT          '.commands.lint'
emit DEVKIT_CMD_FORMAT        '.commands.format'
emit DEVKIT_CMD_TYPECHECK     '.commands.typecheck'
emit DEVKIT_CMD_TEST          '.commands.test'
emit DEVKIT_CMD_E2E           '.commands.e2e'
emit DEVKIT_CMD_BUILD         '.commands.build'

emit DEVKIT_TRACKER           '.tracker.type' 'issues-only'
emit DEVKIT_PROJECT_OWNER     '.tracker.owner'
emit DEVKIT_PROJECT_NUMBER    '.tracker.projectNumber'
emit DEVKIT_PROJECT_ID        '.tracker.projectId'
emit DEVKIT_STATUS_FIELD_ID   '.tracker.statusFieldId'
emit DEVKIT_STATUS_DEFINED    '.tracker.status.defined'
emit DEVKIT_STATUS_READY      '.tracker.status.ready'
emit DEVKIT_STATUS_INPROGRESS '.tracker.status.inProgress'
emit DEVKIT_STATUS_DONE       '.tracker.status.done'
emit DEVKIT_SIZE_FIELD_ID     '.tracker.sizeFieldId'
emit DEVKIT_ESTIMATE_FIELD_ID '.tracker.estimateFieldId'
emit DEVKIT_TAG_FIELD_ID      '.tracker.tagFieldId'

emit DEVKIT_RULES_DIR         '.rules.dir' '.claude/rules'
emit DEVKIT_RULES_REF_DIR     '.rules.referenceDir' 'docs/rules-reference'
emit DEVKIT_RULES_ARCHIVE_DIR '.rules.archiveDir' 'docs/rules-archive'
emit DEVKIT_RULES_MAX_TOTAL   '.rules.maxTotalBytes' '150000'
emit DEVKIT_RULES_MAX_FILE    '.rules.maxFileBytes' '20480'

emit DEVKIT_CYCLES_REQ        '.review.requirementsCycles' '3'
emit DEVKIT_CYCLES_DESIGN     '.review.designCycles' '3'
emit DEVKIT_CYCLES_IMPL       '.review.implementationCycles' '2'
emit DEVKIT_CYCLES_TESTCOV    '.review.testCoverageCycles' '3'
emit DEVKIT_AUDIT_ROUNDS      '.review.auditRounds' '5'
emit DEVKIT_AUDIT_CYCLES      '.review.auditCycles' '3'
emit DEVKIT_VERIFY_RETRIES    '.review.verifyRetries' '3'
emit DEVKIT_CI_FIX_PUSHES     '.review.ciFixPushes' '3'
emit DEVKIT_CI_REVIEW_ROUNDS  '.review.ciReviewRounds' '5'

emit DEVKIT_INFRA_PLATFORM    '.infra.platform'
emit DEVKIT_INFRA_CLOUD       '.infra.cloud'
emit DEVKIT_INFRA_CLUSTER     '.infra.clusterPattern'
emit DEVKIT_INFRA_NAMESPACE   '.infra.namespacePattern'
emit DEVKIT_INFRA_REGISTRY    '.infra.registry'
emit DEVKIT_INFRA_IAC_REPO    '.infra.iacRepo'
emit DEVKIT_INFRA_HEALTH_PATH '.infra.healthPath'
emit DEVKIT_DB_ORM            '.database.orm'

emit DEVKIT_REWORK_STATUS     '.tracker.reworkStatus'
emit DEVKIT_SLACK_CHANNEL     '.report.slackChannelId'

emit DEVKIT_SCHED_COEF        '.schedule.estimateCoefficient' '0.6'
emit DEVKIT_SCHED_HOURS       '.schedule.hoursPerDay' '8'
emit DEVKIT_SCHED_SLOT        '.schedule.slotMinutes' '30'
emit DEVKIT_SCHED_TZ          '.schedule.timeZone' 'Asia/Tokyo'
emit DEVKIT_SCHED_PREFIX      '.schedule.titlePrefix' 'TASK'

emit DEVKIT_VERIFY_BACKEND    '.verify.backend' 'devtools'
emit DEVKIT_VERIFY_BASE_URL   '.verify.baseUrl'
