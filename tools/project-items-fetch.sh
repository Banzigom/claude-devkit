#!/usr/bin/env bash
#
# project-items-fetch.sh — GitHub Project の全 item を安価に取得する
#
# `gh project item-list --limit N` は全件取得に **item 数 × 1 pt 程度**（数百〜千 pt）を
# 消費し、GraphQL プール（5,000 pt/hr）を数回で枯渇させる。生の GraphQL で
# `items(first:100, after:$cursor)` をページングすれば **ページ数 × 1 pt**（約 10 pt）で済む。
#
# コストは **1 リクエスト = 1 pt** でフィールド量に依存しない。取得項目を増やしても
# 増えないので、必要なものは遠慮なく足してよい。
#
# 出力は `gh project item-list --format json` と**同じ形**に正規化する
# （既存の jq をそのまま使えるようにするため）。
#
# 使い方:
#   bash .claude/devkit/project-items-fetch.sh [出力先]     # 既定: /tmp/project_items.json
#   jq '.items[] | select(.status=="In progress")' /tmp/project_items.json
#
# 🔴 単一 Issue の ITEM_ID だけが欲しい場合は本スクリプトを使わない。
#    issue 起点の targeted query（1 pt）を使う。
#
# bash 3.2 (macOS 同梱) 互換で書く。
set -euo pipefail

OUT="${1:-/tmp/project_items.json}"

# 設定は devkit.json から読み、環境変数で上書きできる
OWNER="${PROJECT_OWNER:-}"
NUMBER="${PROJECT_NUMBER:-}"
CONFIG_LOADER=".claude/devkit/config.sh"
if [ -z "$OWNER" ] || [ -z "$NUMBER" ]; then
  if [ -f "$CONFIG_LOADER" ] && DEVKIT_ENV=$(bash "$CONFIG_LOADER" 2>/dev/null); then
    eval "$DEVKIT_ENV"
    OWNER="${OWNER:-${DEVKIT_PROJECT_OWNER:-}}"
    NUMBER="${NUMBER:-${DEVKIT_PROJECT_NUMBER:-}}"
  fi
fi
if [ -z "$OWNER" ] || [ -z "$NUMBER" ]; then
  echo "ERROR: Project の owner / number が未設定（devkit.json の tracker.owner / tracker.projectNumber、または PROJECT_OWNER / PROJECT_NUMBER 環境変数）" >&2
  exit 2
fi

# ページ間の待機（秒）。0 にすると secondary rate limit に触れて
# `Could not resolve to a ProjectV2 with the number N` という
# **権限エラーに見える**メッセージで落ちる（実際は流量制限）。
SLEEP="${PAGE_SLEEP:-1}"

# owner が Organization か User かは事前に分からないので、両方に対応した query を使う。
# 閉じ括弧は query / owner / projectV2 / items / nodes の 5 階層。
# 足りないと `Expected NAME, actual: (none)` になる（括弧不足のサイン）。
build_query() { # build_query <organization|user>
  cat <<GRAPHQL
query(\$owner:String!, \$number:Int!, \$after:String){
  $1(login:\$owner){
    projectV2(number:\$number){
      items(first:100, after:\$after){
        pageInfo{ hasNextPage endCursor }
        nodes{
          id type isArchived updatedAt
          st: fieldValueByName(name:"Status"){ ... on ProjectV2ItemFieldSingleSelectValue{ name } }
          it: fieldValueByName(name:"Iteration"){ ... on ProjectV2ItemFieldIterationValue{ title startDate duration } }
          es: fieldValueByName(name:"Estimate"){ ... on ProjectV2ItemFieldNumberValue{ number } }
          sz: fieldValueByName(name:"Size"){ ... on ProjectV2ItemFieldSingleSelectValue{ name } }
          tg: fieldValueByName(name:"Tag"){ ... on ProjectV2ItemFieldSingleSelectValue{ name } }
          pr: fieldValueByName(name:"Priority"){ ... on ProjectV2ItemFieldSingleSelectValue{ name } }
          content{
            __typename
            ... on Issue{
              number title url state updatedAt closedAt
              repository{ nameWithOwner }
              assignees(first:10){ nodes{ login } }
            }
            ... on PullRequest{
              number title url state updatedAt
              repository{ nameWithOwner }
              assignees(first:10){ nodes{ login } }
            }
          }
        }
      }
    }
  }
}
GRAPHQL
}

ROOT_KIND="organization"
QUERY=$(build_query "$ROOT_KIND")
if ! gh api graphql -f query="$QUERY" -f owner="$OWNER" -F number="$NUMBER" >/dev/null 2>&1; then
  ROOT_KIND="user"
  QUERY=$(build_query "$ROOT_KIND")
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
: > "$TMP"

cursor=""
pages=0
while :; do
  if [ -z "$cursor" ]; then
    resp=$(gh api graphql -f query="$QUERY" -f owner="$OWNER" -F number="$NUMBER")
  else
    resp=$(gh api graphql -f query="$QUERY" -f owner="$OWNER" -F number="$NUMBER" -f after="$cursor")
  fi

  # 取得できたノード数を確認してから追記する。空や取得失敗を「完了」と誤認しない。
  n=$(printf '%s' "$resp" | jq ".data.${ROOT_KIND}.projectV2.items.nodes | length")
  case "$n" in ''|*[!0-9]*) echo "ERROR: item 取得に失敗（page $((pages+1))）" >&2; exit 1 ;; esac
  printf '%s' "$resp" | jq -c ".data.${ROOT_KIND}.projectV2.items.nodes[]" >> "$TMP"
  pages=$((pages + 1))

  has_next=$(printf '%s' "$resp" | jq -r ".data.${ROOT_KIND}.projectV2.items.pageInfo.hasNextPage")
  [ "$has_next" = "true" ] || break
  cursor=$(printf '%s' "$resp" | jq -r ".data.${ROOT_KIND}.projectV2.items.pageInfo.endCursor")
  sleep "$SLEEP"
done

# `gh project item-list --format json` と同じ形へ正規化する。
jq -s '{
  items: [ .[] | {
    id, isArchived, updatedAt,
    status:   (.st.name // null),
    size:     (.sz.name // null),
    tag:      (.tg.name // null),
    priority: (.pr.name // null),
    estimate: (.es.number // null),
    iteration: (if .it then {title: .it.title, startDate: .it.startDate, duration: .it.duration} else null end),
    assignees: [ (.content.assignees.nodes // [])[].login ],
    content: {
      type: (if .type == "ISSUE" then "Issue"
             elif .type == "PULL_REQUEST" then "PullRequest"
             else "DraftIssue" end),
      number:     .content.number,
      title:      .content.title,
      url:        .content.url,
      state:      .content.state,
      updatedAt:  .content.updatedAt,
      closedAt:   .content.closedAt,
      repository: (.content.repository.nameWithOwner // null)
    }
  } ],
  totalCount: length
}' "$TMP" > "$OUT"

count=$(jq '.items | length' "$OUT")
echo "取得 ${count} items / ${pages} pages（${ROOT_KIND}） → ${OUT}"
