#!/usr/bin/env bash
# Passive capture core: distill durable learnings from a transcript slice and
# push them to the team brain. Idempotent via a per-session line offset.
#
# Usage: distill.sh <session_id> <transcript_path>
# Safe to call from Stop (async) and SessionEnd hooks; a per-session lock
# prevents concurrent double-processing.
set -uo pipefail
SID="${1:?session_id}"; TRANSCRIPT="${2:?transcript_path}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$HOME/.claude/.brain"; mkdir -p "$STATE"
OFFSET_FILE="$STATE/offset-$SID"
LOCK="$STATE/lock-$SID"
DISTILL_MODEL="${BRAIN_DISTILL_MODEL:-claude-haiku-4-5-20251001}"

[ -f "$TRANSCRIPT" ] || exit 0
# Lock: skip if another distiller for this session is already running.
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

total="$(wc -l < "$TRANSCRIPT" 2>/dev/null || echo 0)"
offset="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"
[ "$total" -gt "$offset" ] || exit 0   # nothing new

# Render the new slice to readable text: user prompts + assistant text + tool names.
slice="$(tail -n +"$((offset+1))" "$TRANSCRIPT" 2>/dev/null | jq -rc '
  select(.type=="user" or .type=="assistant")
  | if .type=="user" then
      (.message.content
       | if type=="string" then "USER: " + .
         else ((.[]? | select(.type=="text") | "USER: " + .text) // empty) end)
    else
      (.message.content[]?
       | if .type=="text" then "ASSISTANT: " + .text
         elif .type=="tool_use" then "ASSISTANT[used tool: " + (.name//"?") + "]"
         else empty end)
    end' 2>/dev/null)"

# Cheap substance gate: bail if the slice is essentially empty.
[ "$(printf '%s' "$slice" | tr -d '[:space:]' | wc -c)" -ge 40 ] || { echo "$total" > "$OFFSET_FILE"; exit 0; }

read -r -d '' INSTRUCTION <<'EOF'
You are the memory distiller for a software team's shared "brain". Read the Claude Code
session excerpt on stdin and extract ONLY durable, reusable knowledge worth remembering
for the whole team: decisions made, factual project/infra details, conventions adopted,
user/team preferences, gotchas, root-cause fixes, architecture. INCLUDE things stated in
plain conversation (e.g. "remember that X"), not just things that touched files.
EXCLUDE: transient debugging chatter, step-by-step narration, anything ephemeral or
trivial, and ANY secrets/tokens/keys/passwords.
Output STRICT JSON only: an array of objects {"content": "...", "type": "fact|decision|lesson"}.
Each "content" must be ONE atomic fact, self-contained and understandable with no other
context. If nothing is worth remembering, output exactly [].
EOF

# Distill locally on the user's own Claude (keyless). BRAIN_DISTILLER guards against
# this child session's own hooks re-triggering capture (infinite recursion).
raw="$(printf '%s' "$slice" | BRAIN_DISTILLER=1 timeout 120 claude -p "$INSTRUCTION" \
        --model "$DISTILL_MODEL" --output-format text 2>/dev/null)"
[ -n "$raw" ] || { echo "$total" > "$OFFSET_FILE"; exit 0; }

# Tolerate code fences / stray prose around the JSON array.
json="$(printf '%s' "$raw" | sed -n '/\[/,/\]/p')"
echo "$json" | jq empty 2>/dev/null || { echo "$total" > "$OFFSET_FILE"; exit 0; }

# Secret scrub on the way out (belt-and-suspenders over the prompt instruction).
scrub() { sed -E \
  -e 's/(sk-[A-Za-z0-9_-]{12,})/[REDACTED]/g' \
  -e 's/(sk-ant-[A-Za-z0-9_-]{12,})/[REDACTED]/g' \
  -e 's/([A-Za-z0-9_-]*(SECRET|TOKEN|PASSWORD|API_KEY|APIKEY)[A-Za-z0-9_-]*[=:][[:space:]]*)[^[:space:]"]+/\1[REDACTED]/gI' \
  -e 's/\b([0-9a-f]{32,})\b/[REDACTED]/g' \
  -e 's/(AKIA[0-9A-Z]{16})/[REDACTED]/g'; }

count=0
while IFS= read -r row; do
  content="$(printf '%s' "$row" | jq -r '.content // empty' | scrub)"
  typ="$(printf '%s' "$row" | jq -r '.type // "fact"')"
  [ -n "$content" ] || continue
  BRAIN_DISTILLER=1 bash "$SKILL_DIR/brain.sh" remember "$content" "$typ" >/dev/null 2>&1 && count=$((count+1))
done < <(echo "$json" | jq -c '.[]?' 2>/dev/null)

echo "$total" > "$OFFSET_FILE"
[ "$count" -gt 0 ] && echo "[team-brain] captured $count learning(s) from session $SID" >&2
exit 0
