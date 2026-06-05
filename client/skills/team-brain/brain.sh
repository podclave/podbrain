#!/usr/bin/env bash
# team-brain client helper — a thin curl wrapper over the shared brain REST API.
# Subcommands: recall <query> | remember <text> [type] | file <path> [note] | health
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$DIR/brain.env" ] && . "$DIR/brain.env"
: "${BRAIN_URL:?set BRAIN_URL in brain.env}"
: "${BRAIN_SECRET:?set BRAIN_SECRET in brain.env}"
# Identity resolution (no per-user config needed):
#   1. BRAIN_USER override (rarely set)
#   2. Podclave-provisioned identity file (dropped per-VM, like control-url)
#   3. git email  4. $USER
USER_ID="${BRAIN_USER:-}"
for f in "$HOME/.podclave/user-email" "$HOME/.podclave/email"; do
  [ -z "$USER_ID" ] && [ -f "$f" ] && USER_ID="$(tr -d '[:space:]' < "$f")"
done
[ -z "$USER_ID" ] && USER_ID="$(git config user.email 2>/dev/null || echo "${USER:-unknown}")"
AUTH="Authorization: Bearer $BRAIN_SECRET"
api() { curl -sS --max-time 25 -H "$AUTH" -H "Content-Type: application/json" "$@"; }

cmd="${1:-help}"; shift || true
case "$cmd" in
  recall)
    q="${1:?usage: brain.sh recall <query>}"; k="${2:-5}"
    # smart-search returns truncated titles; expand each top hit to full content.
    ids="$(api -X POST "$BRAIN_URL/agentmemory/smart-search" \
            -d "$(jq -nc --arg q "$q" '{query:$q}')" \
          | jq -r --argjson k "$k" '[.results[]?.obsId] | .[0:$k] | .[]' 2>/dev/null)"
    [ -n "$ids" ] || exit 0
    for id in $ids; do
      api "$BRAIN_URL/agentmemory/memories/$id" \
        | jq -r '(.content // .memory.content // .title // .memory.title // empty) | select(.!="") | "• " + .' 2>/dev/null
    done
    ;;
  remember)
    t="${1:?usage: brain.sh remember <text> [type]}"; typ="${2:-fact}"
    # agentmemory's REST drops user/tags, so embed author for provenance.
    # (The gateway will own first-class attribution later.)
    body="$t  —[saved by $USER_ID]"
    api -X POST "$BRAIN_URL/agentmemory/remember" \
      -d "$(jq -nc --arg c "$body" --arg ty "$typ" '{content:$c, type:$ty}')" \
      | jq -r '.memory.id // .id // .status // "saved"'
    ;;
  file)
    p="${1:?usage: brain.sh file <path> [note]}"; note="${2:-}"
    [ -f "$p" ] || { echo "no such file: $p" >&2; exit 1; }
    curl -sS --max-time 180 -H "$AUTH" \
      -F "file=@${p}" -F "note=${note}" -F "user=${USER_ID}" \
      "$BRAIN_URL/ingest/upload"
    ;;
  health) api "$BRAIN_URL/agentmemory/health" ;;
  *) echo "usage: brain.sh {recall <q>|remember <text> [type]|file <path> [note]|health}" >&2 ;;
esac
