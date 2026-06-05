#!/usr/bin/env bash
# UserPromptSubmit hook: inject relevant team-brain knowledge as context.
# Fail-open and fast — never block or slow the prompt noticeably.
set -uo pipefail
# Don't inject context into our own distiller's claude -p child session.
[ -n "${BRAIN_DISTILLER:-}" ] && exit 0
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
input="$(cat)"
prompt="$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null)"
[ -n "$prompt" ] || exit 0
ctx="$(timeout 12 bash "$DIR/../brain.sh" recall "$prompt" 2>/dev/null || true)"
[ -n "$ctx" ] || exit 0
printf '<team-brain-context>\n# Relevant shared knowledge from the team brain (recall before answering):\n%s\n</team-brain-context>\n' "$ctx"
