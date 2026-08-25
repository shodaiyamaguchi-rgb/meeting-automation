#!/usr/bin/env bash
# 会議議事録の自動化ランナー
#
#   ./run.sh <prompt-name> [target-date]
#
#   prompt-name : prompts/<name>.md のファイル名（拡張子なし）
#   target-date : YYYY-MM-DD / today / yesterday（既定：today、JST基準）
#
# 例：
#   ./run.sh board-weekly-minutes              # 本日の回の議事録を生成
#   ./run.sh board-weekly-minutes yesterday    # 翌朝08:00のリトライ用
#   ./run.sh board-weekly-minutes 2026-08-25   # 日付を指定して再実行
#
# 環境変数：
#   DRY_RUN=1   組み立てたプロンプトを表示するだけで、claude を起動しない
#   CLAUDE_BIN  claude コマンドのパス（既定：claude）

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
TZ_JST="Asia/Tokyo"

usage() { sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

[ $# -ge 1 ] || usage
PROMPT_NAME="$1"
DATE_ARG="${2:-today}"

PROMPT_FILE="$ROOT/prompts/$PROMPT_NAME.md"
SHARED_FILE="$ROOT/prompts/_shared-rules.md"
CONFIG_FILE="$ROOT/config/meetings.json"

for f in "$PROMPT_FILE" "$SHARED_FILE" "$CONFIG_FILE"; do
  if [ ! -f "$f" ]; then
    echo "run.sh: 見つかりません: $f" >&2
    [ "$f" = "$PROMPT_FILE" ] && { echo "利用可能なプロンプト:" >&2; ls -1 "$ROOT/prompts" | grep -v '^_' | sed 's/\.md$/  /' >&2; }
    exit 2
  fi
done

# --- 対象日を JST で解決 ---------------------------------------------------
case "$DATE_ARG" in
  today)     TARGET_DATE="$(TZ=$TZ_JST date +%F)" ;;
  yesterday) TARGET_DATE="$(TZ=$TZ_JST date -d 'yesterday' +%F)" ;;
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) TARGET_DATE="$DATE_ARG" ;;
  *) echo "run.sh: 対象日の形式が不正です: $DATE_ARG（YYYY-MM-DD / today / yesterday）" >&2; exit 2 ;;
esac
NOW_JST="$(TZ=$TZ_JST date '+%F %H:%M %Z')"

# --- 同じプロンプトの多重起動を防ぐ ----------------------------------------
LOCK_FILE="$ROOT/logs/$PROMPT_NAME.lock"
mkdir -p "$ROOT/logs"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "run.sh: $PROMPT_NAME は既に実行中です。今回は起動しません。" >&2
  exit 0
fi

LOG_FILE="$ROOT/logs/$(TZ=$TZ_JST date +%Y%m%d-%H%M%S)-$PROMPT_NAME.log"

# --- プロンプトを組み立てる ------------------------------------------------
build_prompt() {
  cat "$SHARED_FILE"
  printf '\n\n---\n\n# 実行時コンテキスト\n\n'
  printf '%s\n' "- TARGET_DATE（対象日／JST）：$TARGET_DATE"
  printf '%s\n' "- 実行時刻：$NOW_JST"
  printf '%s\n\n' "- 「本日」「当日」はすべて TARGET_DATE を指す。実行日ではない。"
  printf '## config/meetings.json\n\n```json\n'
  cat "$CONFIG_FILE"
  printf '\n```\n\n---\n\n'
  cat "$PROMPT_FILE"
}

if [ "${DRY_RUN:-0}" = "1" ]; then
  build_prompt
  exit 0
fi

if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  echo "run.sh: $CLAUDE_BIN が見つかりません。CLAUDE_BIN でパスを指定してください。" >&2
  exit 127
fi

echo "=== $PROMPT_NAME / 対象日 $TARGET_DATE / 起動 $NOW_JST ===" | tee -a "$LOG_FILE"

set +e
build_prompt | "$CLAUDE_BIN" -p --output-format text 2>&1 | tee -a "$LOG_FILE"
STATUS=${PIPESTATUS[1]}
set -e

echo "=== 終了 $(TZ=$TZ_JST date '+%F %H:%M %Z') / exit=$STATUS ===" | tee -a "$LOG_FILE"
exit "$STATUS"
