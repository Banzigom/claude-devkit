---
name: daily-schedule
description: GitHub Project から操作ユーザー担当の Issue を現イテレーション（足りなければ次）の作業対象 Status で拾い、Estimate × 係数で所要を出して本日のスケジュールを組み、カレンダーへ既存予定と被らないように反映する。起動直後に書き込み先アカウントの同意を取り、稼働時間と Issue 以外のタスクを尋ねる。「本日の予定」「今日のスケジュール」「daily-schedule」「スケジュール組んで」「カレンダーに入れて」と言われた時に使用してください。
allowed-tools: Bash(bash *), Bash(gh *), Bash(jq *), Bash(date *), Read, AskUserQuestion, mcp__claude_ai_Google_Calendar__list_calendars, mcp__claude_ai_Google_Calendar__list_events, mcp__claude_ai_Google_Calendar__create_event, mcp__claude_ai_Google_Calendar__update_event, mcp__claude_ai_Google_Calendar__get_event
---

# daily-schedule — 本日のスケジュール組み立て

GitHub Project から**操作ユーザー本人**の対応すべき Issue を拾い、本日の作業スケジュールを組み、カレンダーへ反映する。既存予定と被らない空き時間に作業ブロックを置く。

**このスキルはリポジトリ共有。操作ユーザーは実行時に動的解決する**（`gh api user`）— 誰が実行しても本人の担当が対象になる。

`tracker.type` が `github-project` でなければ使えない。その旨を伝えて停止する。

## 前提

```bash
DEVKIT_ENV=$(bash "$(git rev-parse --show-toplevel)/.claude/devkit/config.sh") || exit 1
eval "$DEVKIT_ENV"
[ "$DEVKIT_TRACKER" = "github-project" ] || { echo "tracker.type が github-project でないため利用不可"; exit 0; }
```

| 設定 | 参照元 |
|---|---|
| 対象 Status | `tracker.workableStatuses` |
| Estimate 換算係数 | `schedule.estimateCoefficient`（既定 0.6） |
| 1 人日の時間 | `schedule.hoursPerDay`（既定 8） |
| 時間の丸め | `schedule.slotMinutes`（既定 30 分・**切り上げ**） |
| タイムゾーン | `schedule.timeZone` |
| タイトル接頭辞 | `schedule.titlePrefix`（既定 `TASK`） |

**所要 = `Estimate × 係数 × hoursPerDay`** を `slotMinutes` 単位に切り上げる。開始 / 終了時刻も同じ単位に丸める。

**Estimate 未設定は 1 人日と仮置きし、ドラフトで明示する**（黙って埋めない。本来は Issue 側で見積もるべきもの）。

## カレンダーの扱い

- 書き込み先は**接続中アカウントの primary カレンダー**。接続アカウントはカレンダー連携側で決まる
- 🔴 **書き込み先アカウントは起動直後に提示して同意を取る**（処理の最後ではなく最初）。散々進めてから「そのアカウントではない」と分かるのが最悪
- 実イベント作成はドラフト承認後。**アカウント同意（最初）＋ 書き込み内容の承認（直前）の 2 段ゲート**

## 手順

### 1. 起動時のヒアリング（1 問ずつ）

🔴 **`AskUserQuestion` を 1 項目につき 1 回呼ぶ。複数項目を 1 回のダイアログにまとめない。** プレーンテキストで列挙して一括で聞くのも禁止。前の回答を受けてから次を聞く。

1. **書き込み先アカウントの確認** — `list_calendars` で primary を特定し、「この宛先でよいか」を確認する。違う → **停止して**連携の繋ぎ直しを案内する。連携が無い / エラー → 停止して接続を案内する
2. **稼働時間** — **固定の時間帯候補で縛らない**（プリセットを押し付けない）。自由入力で受ける前提にする
3. **Issue 以外のタスク** — 有無を尋ね、あれば内容 / 所要 / 希望時間帯を自由入力で受ける

### 2. 操作ユーザー解決 + Project 取得（毎回 fresh）

🔴 **キャッシュを使い回さない**（古い Status を掴むと対象を取りこぼす）。

```bash
LOGIN=$(gh api user --jq .login)
TODAY=$(TZ="$DEVKIT_SCHED_TZ" date +%Y-%m-%d)
bash "$DEVKIT_ROOT/.claude/devkit/project-items-fetch.sh" /tmp/ds_items.json   # 毎回上書き（約 10 pt）
```

イテレーションは items の `iteration.startDate` から判定する（today 以下で最新 = current、today より後で最小 = next）:

```bash
CUR=$(jq -r --arg t "$TODAY" '[.items[].iteration//empty]|unique_by(.title)|map(select(.startDate<=$t))|sort_by(.startDate)|last|.title//"-"' /tmp/ds_items.json)
NEXT=$(jq -r --arg t "$TODAY" '[.items[].iteration//empty]|unique_by(.title)|map(select(.startDate>$t))|sort_by(.startDate)|first|.title//"-"' /tmp/ds_items.json)
```

> Project の読み取りには `project` scope が要る。読めなければ `gh auth status` で active アカウントを確認する。

### 3. 対象スコープの抽出

**対象 = 現イテレーションかつ `tracker.workableStatuses` に含まれる Status。** これで本日の容量を満たせなければ**次イテレーションを追加**する。

```bash
LOGIN=$(gh api user --jq .login)
WORKABLE=$(jq -c '.tracker.workableStatuses // []' "$DEVKIT_CONFIG")
jq --arg me "$LOGIN" --argjson w "$WORKABLE" '[.items[]
  | select(.content.type=="Issue")
  | select((.assignees//[])|index($me))
  | select(.status as $s | ($w|index($s)))
  | {n:.content.number,t:.content.title,s:.status,e:(.estimate//null),
     p:(.priority//null),it:(.iteration.title//null)} ]' /tmp/ds_items.json > /tmp/ds_tgt.json
```

`workableStatuses` が空なら、**items に実在する Status を一覧して「どれを本日の対象にするか」をユーザーに確認**する（決め打ちしない）。確認結果は `devkit.json` へ保存することを提案する。

### 4. 並び順

1. **Priority 主軸**（設定されているものを上位）
2. 同 Priority 内 — 締切（イテレーション終了）が近い順 → Status の手前側優先。**差し戻し系の Status は上位に置く**（一度出したものが戻っている＝着手優先度が高い）
3. Priority 未設定 — 取得順のまま（並べ替えない）

現イテレーションを上記順に並べ、次イテレーションの追加分をその後ろに同順で続ける。

### 5. 既存予定の取得（衝突回避）

その日の 00:00–23:59 を `list_events` で取得する。

- 既存イベントの開始–終了を **busy** として被らせない。不在（out of office）も busy 扱い
- タイトルに休憩・昼食を示す語を含む予定は休憩として尊重する。🔴 **それ以外の休憩を勝手に挿入しない**（夕食等を足さない）
- この一覧は手順 7 の重複判定にも使う

### 6. 時間の割り当て

- 稼働開始から、既存予定を避けて手順 4 の順にブロックを置く
- 🔴 **Issue は途中で切らない。** 所要を満たす区切りまでブロックを延長する（既存予定を跨ぐなら前後に分割し、合計が所要に達するまで充てる）
- 稼働終了をブロックが越えても、着手中の Issue は所要を満たすまで延長してよい（深夜跨ぎになる場合はドラフトで明示する）
- 稼働時間が埋まったら以降は「本日未割り当て」として列挙する

### 7. ドラフト提示・承認（書き込み前ゲート）

時系列の表で提示する。各行: 時刻帯 / 区分 / `#番号` / タイトル / 備考（Estimate → 所要・Priority・締切・**仮置きの有無**）。既存予定と未割り当ても列挙する。

**ここで承認を取るのは「書き込む内容」**（アカウントは手順 1 で同意済み）。外部書き込みは不可逆。

### 8. カレンダー反映（重複回避）

承認後にブロックごと作成する。

- **タイトル**: `<titlePrefix>: #<番号> <タイトル>`（Issue 以外は `<titlePrefix>: <タイトル>`）
- 🔴 **冪等性**: 手順 5 で取得した当日の予定を見て、**同じ `<titlePrefix>: #<番号>` が既にあれば作らない**。時刻違いなら更新する。**再実行で重複させない**
- 反映後、作成 / 更新 / スキップの件数を報告する

## 合格基準

- 起動**直後**に書き込み先アカウントを提示して同意を得ている
- 稼働時間・Issue 以外タスクを 1 問ずつ確認している
- 対象は操作ユーザー本人の担当のみ。対象外 Status を含めていない
- Project データを毎回 fresh 取得している
- 所要・開始 / 終了が `slotMinutes` 単位。Issue を途中で切っていない
- 休憩を勝手に足していない
- 既存予定に重なるブロックが 0
- 書き込み前にドラフトを承認している。再実行で重複イベントが無い

## 進捗ログ

- 起動: `▶ /daily-schedule（user=<login>, today=<date>）`
- アカウント同意: `📅 書き込み先: <account>（同意取得）`
- 抽出: `現=<title> 対象 a 件 / 次=<title> 追加 b 件`
- ドラフト: `🗓 ドラフト提示（割当 X / 未割当 Y）`
- 反映: `✅ 反映: 作成 p / 更新 q / スキップ r`

## Notes

- **Estimate の単位は「人日」を前提**にしている（`/define-requirements` が入れる値）。別単位を使うなら `schedule.hoursPerDay` を合わせる
- **休憩・食事を推測で挿入しない。** 既存予定だけを尊重する
- Priority はチーム入力が前提。未入力なら取得順に倒れる（埋まるほど精度が上がる）
