#!/usr/bin/env bash
# Stop hook (registered with "async": true). The async Stop-gate: on each turn,
# debounce ~90s and, if no newer turn arrived, distill the new transcript slice.
# Fires per-turn but only the LAST turn in a burst does the work.
set -uo pipefail
# Recursion guard: never capture our own distiller's claude -p child session.
[ -n "${BRAIN_DISTILLER:-}" ] && exit 0
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$HOME/.claude/.brain"; mkdir -p "$STATE"
DEBOUNCE="${BRAIN_DEBOUNCE_SECS:-90}"

input="$(cat)"
SID="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
TRANSCRIPT="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"
[ -n "$SID" ] && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0

# Debounce: stamp this turn; if a newer turn stamps after we wake, let it win.
PING="$STATE/ping-$SID"
TS="$(date +%s%N)"
echo "$TS" > "$PING"
sleep "$DEBOUNCE"
[ "$(cat "$PING" 2>/dev/null)" = "$TS" ] || exit 0   # newer turn arrived → bail

bash "$DIR/../capture/distill.sh" "$SID" "$TRANSCRIPT"
exit 0
