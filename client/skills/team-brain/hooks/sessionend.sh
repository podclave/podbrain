#!/usr/bin/env bash
# SessionEnd backstop: flush any uncaptured tail immediately on clean session end
# (no debounce — there are no further turns coming). Belt-and-suspenders to the
# async Stop-gate; with Podclave's 15-min uptime guarantee the Stop-gate usually
# already ran, and the per-session offset makes this idempotent.
set -uo pipefail
[ -n "${BRAIN_DISTILLER:-}" ] && exit 0
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
input="$(cat)"
SID="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
TRANSCRIPT="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"
[ -n "$SID" ] && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0
bash "$DIR/../capture/distill.sh" "$SID" "$TRANSCRIPT"
exit 0
