#!/usr/bin/env bash
# team-brain — single-file client for the shared team brain.
# Subcommands:
#   recall <query>            bulleted relevant memories (full content)
#   remember <text> [type]    save a memory (fact|decision|lesson)
#   file <path> [note]        ingest a document (pdf/docx/pptx/md...)
#   health                    service check
#   hook-recall               UserPromptSubmit hook: inject <team-brain-context>
#   hook-stop                 Stop hook (async): debounce + passive capture
#   hook-sessionend           SessionEnd hook: capture backstop
#   distill <sid> <path>      distill durable learnings from a transcript slice
#
# Config (BRAIN_URL, BRAIN_SECRET): from the environment if set, else sourced
# from ~/.env.podclave.brain (Podclave overlay) or ./brain.env (manual).
# Identity: ~/.podclave/user-email, falling back to git email / $USER.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${BRAIN_URL:-}" ] || [ -z "${BRAIN_SECRET:-}" ]; then
  for f in "$HOME/.env.podclave.brain" "$DIR/brain.env"; do [ -f "$f" ] && . "$f"; done
fi
: "${BRAIN_URL:?set BRAIN_URL (env or ~/.env.podclave.brain)}"
: "${BRAIN_SECRET:?set BRAIN_SECRET (env or ~/.env.podclave.brain)}"

USER_ID="${BRAIN_USER:-}"
[ -z "$USER_ID" ] && [ -f "$HOME/.podclave/user-email" ] && USER_ID="$(tr -d '[:space:]' < "$HOME/.podclave/user-email")"
[ -z "$USER_ID" ] && USER_ID="$(git config user.email 2>/dev/null || echo "${USER:-unknown}")"

STATE="$HOME/.claude/.brain"
AUTH="Authorization: Bearer $BRAIN_SECRET"
api(){ curl -sS --max-time 25 -H "$AUTH" -H "Content-Type: application/json" "$@"; }

do_recall(){ # <query> [k]
  local q="$1" k="${2:-5}" ids id
  ids="$(api -X POST "$BRAIN_URL/agentmemory/smart-search" -d "$(jq -nc --arg q "$q" '{query:$q}')" \
        | jq -r --argjson k "$k" '[.results[]?.obsId] | .[0:$k] | .[]' 2>/dev/null)"
  [ -n "$ids" ] || return 0
  for id in $ids; do
    api "$BRAIN_URL/agentmemory/memories/$id" \
      | jq -r '(.content // .memory.content // .title // .memory.title // empty) | select(.!="") | "• " + .' 2>/dev/null
  done
}

do_remember(){ # <text> [type]
  local typ="${2:-fact}" body="$1  —[saved by $USER_ID]"
  api -X POST "$BRAIN_URL/agentmemory/remember" -d "$(jq -nc --arg c "$body" --arg ty "$typ" '{content:$c, type:$ty}')" \
    | jq -r '.memory.id // .id // .status // "saved"'
}

do_distill(){ # <session_id> <transcript_path>
  local SID="$1" TRANSCRIPT="$2"
  mkdir -p "$STATE"
  local OFFSET_FILE="$STATE/offset-$SID" LOCK="$STATE/lock-$SID"
  local MODEL="${BRAIN_DISTILL_MODEL:-claude-haiku-4-5-20251001}"
  [ -f "$TRANSCRIPT" ] || return 0
  # Single-flight per session via flock — auto-releases on process exit, so a
  # killed run never leaves a stale lock (and the fd closes when this fn's process ends).
  exec 9>"$LOCK" 2>/dev/null || return 0
  flock -n 9 2>/dev/null || return 0
  local total offset; total="$(wc -l < "$TRANSCRIPT" 2>/dev/null || echo 0)"; offset="$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)"
  [ "$total" -gt "$offset" ] || return 0
  # Render user/assistant text only; drop isMeta entries (skill-load dumps), and
  # strip injected <team-brain-context> blocks so the brain never re-ingests what
  # it recalled (the feedback loop).
  local slice; slice="$(tail -n +"$((offset+1))" "$TRANSCRIPT" 2>/dev/null | jq -rc '
    select((.type=="user" or .type=="assistant") and ((.isMeta // false)==false))
    | if .type=="user" then (.message.content | if type=="string" then "USER: "+. else ((.[]?|select(.type=="text")|"USER: "+.text)//empty) end)
      else (.message.content[]? | if .type=="text" then "ASSISTANT: "+.text elif .type=="tool_use" then "ASSISTANT[used tool: "+(.name//"?")+"]" else empty end) end' 2>/dev/null \
    | sed '/<team-brain-context>/,/<\/team-brain-context>/d')"
  [ "$(printf '%s' "$slice" | tr -d '[:space:]' | wc -c)" -ge 40 ] || { echo "$total" > "$OFFSET_FILE"; return 0; }
  local INSTRUCTION='You are the memory distiller for a software team'\''s shared brain. Read the Claude Code session excerpt on stdin and extract ONLY durable, reusable knowledge worth remembering for the whole team: decisions, factual project/infra details, conventions, preferences, gotchas, root-cause fixes, architecture. INCLUDE things newly stated by the user or newly discovered/decided in THIS session. CRITICAL: do NOT extract facts that were merely recalled from the team brain or recited from prior knowledge (e.g. an assistant answering "here is what we know..." with already-stored facts) — those are already saved; capture only NEW information. EXCLUDE transient chatter, narration, task-execution requests (e.g. "create a file containing X"), anything trivial, and ANY secrets/tokens/keys. Output STRICT JSON only: an array of {"content":"...","type":"fact|decision|lesson"}, each content one atomic self-contained fact. If nothing is worth remembering, output exactly [].'
  local raw json rc; raw="$(printf '%s' "$slice" | BRAIN_DISTILLER=1 timeout 120 claude -p "$INSTRUCTION" --model "$MODEL" --output-format text 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || return 0   # claude failed/timed out: leave offset unchanged so we retry the slice
  [ -n "$raw" ] || { echo "$total" > "$OFFSET_FILE"; return 0; }
  json="$(printf '%s' "$raw" | sed -n '/\[/,/\]/p')"; echo "$json" | jq empty 2>/dev/null || { echo "$total" > "$OFFSET_FILE"; return 0; }
  scrub(){ sed -E -e 's/(sk-(ant-)?[A-Za-z0-9_-]{12,})/[REDACTED]/g' \
    -e 's/([A-Za-z0-9_-]*(SECRET|TOKEN|PASSWORD|API_KEY|APIKEY)[A-Za-z0-9_-]*[=:][[:space:]]*)[^[:space:]"]+/\1[REDACTED]/gI' \
    -e 's/\b([0-9a-f]{32,})\b/[REDACTED]/g' -e 's/(AKIA[0-9A-Z]{16})/[REDACTED]/g'; }
  local count=0 content typ row
  while IFS= read -r row; do
    content="$(printf '%s' "$row" | jq -r '.content // empty' | scrub)"; typ="$(printf '%s' "$row" | jq -r '.type // "fact"')"
    [ -n "$content" ] || continue
    BRAIN_DISTILLER=1 do_remember "$content" "$typ" >/dev/null 2>&1 && count=$((count+1))
  done < <(echo "$json" | jq -c '.[]?' 2>/dev/null)
  echo "$total" > "$OFFSET_FILE"
  [ "$count" -gt 0 ] && echo "[team-brain] captured $count learning(s) from session $SID" >&2
  return 0
}

# Capture must survive (a) Claude cancelling the hook on shutdown and (b) the box
# auto-suspending mid-distill. So every distill runs DETACHED (setsid) and holds a
# Sprite keep-alive task for its duration. The keep-alive uses `sprite-env curl`
# (the platform's own tasks API) and no-ops gracefully when not on a Sprite.
sprite_task(){ command -v sprite-env >/dev/null 2>&1 && sprite-env curl "$@" >/dev/null 2>&1 || true; }
kp_distill(){ # <sid> <transcript>
  # Fixed-name keep-alive: each POST upserts/extends the 1m TTL (concurrency-safe;
  # self-cleans via expiry — no DELETE). If a slow distill outlives the TTL, the
  # rc-gated offset + SessionStart sweep just retry it. No-op off-Sprite.
  sprite_task -X POST /v1/tasks -d '{"name":"brain-capture","expire":"1m"}'
  do_distill "$1" "$2"
}
detach(){ setsid bash "$DIR/brain.sh" "$@" >/dev/null 2>&1 </dev/null & }

cmd="${1:-help}"; shift || true
case "$cmd" in
  recall)   do_recall "${1:?usage: recall <query>}" "${2:-5}" ;;
  remember) do_remember "${1:?usage: remember <text> [type]}" "${2:-fact}" ;;
  file)
    p="${1:?usage: file <path> [note]}"; note="${2:-}"
    [ -f "$p" ] || { echo "no such file: $p" >&2; exit 1; }
    curl -sS --max-time 180 -H "$AUTH" -F "file=@${p}" -F "note=${note}" -F "user=${USER_ID}" "$BRAIN_URL/ingest/upload" ;;
  health)   api "$BRAIN_URL/agentmemory/health" ;;
  distill)  do_distill "${1:?sid}" "${2:?transcript}" ;;
  hook-recall)
    [ -n "${BRAIN_DISTILLER:-}" ] && exit 0
    prompt="$(cat | jq -r '.prompt // empty' 2>/dev/null)"; [ -n "$prompt" ] || exit 0
    ctx="$(timeout 12 bash "$DIR/brain.sh" recall "$prompt" 2>/dev/null || true)"; [ -n "$ctx" ] || exit 0
    printf '<team-brain-context>\n# Relevant shared knowledge from the team brain (recall before answering):\n%s\n</team-brain-context>\n' "$ctx" ;;
  hook-stop)
    # Detach a debounced capture that survives /exit (setsid) and spin-down (keep-alive).
    [ -n "${BRAIN_DISTILLER:-}" ] && exit 0
    mkdir -p "$STATE"; input="$(cat)"
    SID="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
    TR="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"
    [ -n "$SID" ] && [ -n "$TR" ] && [ -f "$TR" ] || exit 0
    TS="$(date +%s%N)"; echo "$TS" > "$STATE/ping-$SID"
    detach _bgstop "$SID" "$TR" "$TS" ;;
  hook-sessionend)
    # Detach immediate capture — returns fast so Claude doesn't cancel it on shutdown.
    [ -n "${BRAIN_DISTILLER:-}" ] && exit 0
    input="$(cat)"
    SID="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
    TR="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"
    [ -n "$SID" ] && [ -n "$TR" ] && [ -f "$TR" ] || exit 0
    detach _bgnow "$SID" "$TR" ;;
  hook-sessionstart)
    # Catch-up backstop: at the start of a session (box guaranteed awake), sweep any
    # recent transcript whose capture was missed (killed Stop/SessionEnd). Detached.
    [ -n "${BRAIN_DISTILLER:-}" ] && exit 0
    SID="$(cat | jq -r '.session_id // empty' 2>/dev/null)"
    detach _bgsweep "${SID:-none}" ;;
  _bgstop)
    sleep "${BRAIN_DEBOUNCE_SECS:-90}"
    [ "$(cat "$STATE/ping-$1" 2>/dev/null)" = "$3" ] || exit 0   # a newer turn won; let it capture
    kp_distill "$1" "$2" ;;
  _bgnow)
    kp_distill "$1" "$2" ;;
  _bgsweep)
    cur="${1:-none}"
    for tr in $(find "$HOME/.claude/projects" -name '*.jsonl' -mmin -2880 2>/dev/null); do
      sid="$(basename "$tr" .jsonl)"
      [ "$sid" = "$cur" ] && continue
      # skip the distiller's own `claude -p` transcripts (would re-ingest)
      head -c 4000 "$tr" 2>/dev/null | grep -q "memory distiller for a software team" && continue
      kp_distill "$sid" "$tr"
    done ;;
  *) echo "usage: brain.sh {recall|remember|file|health|distill|hook-recall|hook-stop|hook-sessionend|hook-sessionstart}" >&2 ;;
esac
