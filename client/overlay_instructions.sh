#!/usr/bin/env bash
# overlay_instructions.sh — print every team-brain client overlay (destination path +
# contents) to stdout, ready to copy-paste into the Podclave "team-brain" config bundle.
#
# Usage (after cloning podbrain on the server box):
#   bash client/overlay_instructions.sh
#
# The mapping below is the authoritative bundle list (paths + owners) — README.md
# describes what each overlay is and why. Contents come straight from the repo, so
# this is always current with whatever you just pulled.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"

# owner | overlay dest (on the client; relative paths land in $HOME) | repo source (rel. to client/) | note
overlays=(
  "user|.claude/skills/team-brain/SKILL.md|plugin/skills/team-brain/SKILL.md|"
  "user|.claude/skills/team-brain/brain.py|plugin/skills/team-brain/brain.py|"
  "user|.env.podclave.brain|env.podclave.brain.template|SECRETS: set real BRAIN_URL/BRAIN_SECRET here (values live in Podclave, never git)"
  "root|/etc/claude-code/managed-settings.d/20-team-brain.json|managed-settings.d/20-team-brain.json|"
  "root|/etc/claude-code/managed-mcp.json|managed-mcp.json|"
)

# The env overlay (#3) is the only one with secrets — git holds just a placeholder
# template. But this script normally runs ON the brain box, which has the live values,
# so we pre-fill them: BRAIN_SECRET from ~/.agentmemory/team_secret.txt and BRAIN_URL
# from `sprite-env info` (the same source install-brain.sh uses). Run off-box (no
# secret/URL available) it falls back to the placeholder template untouched.
ENV_TEMPLATE="env.podclave.brain.template"
brain_secret="$( [[ -f "$HOME/.agentmemory/team_secret.txt" ]] && cat "$HOME/.agentmemory/team_secret.txt" || true )"
brain_url="$(sprite-env info 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("sprite_url",""))' 2>/dev/null || true)"

n=${#overlays[@]}
printf '################################################################\n'
printf '# team-brain client overlays — %d files for the Podclave bundle\n' "$n"
printf '# Paste each block below at the shown overlay path, with the noted owner.\n'
printf '# Relative paths land in $HOME. Source of truth: this repo (client/).\n'
if [[ -n "$brain_secret" && -n "$brain_url" ]]; then
  printf '# NOTE: overlay #3 below is PRE-FILLED with this brain'\''s live URL + secret.\n'
  printf '#       That block contains the real bearer secret — paste it into Podclave,\n'
  printf '#       do not commit or share it.\n'
fi
printf '################################################################\n'

i=0
for row in "${overlays[@]}"; do
  IFS='|' read -r owner dest src note <<<"$row"
  i=$((i + 1))
  src_path="$here/$src"
  if [[ ! -f "$src_path" ]]; then
    printf 'ERROR: missing overlay source: %s\n' "$src_path" >&2
    exit 1
  fi

  # Pre-fill the secrets file in place of the placeholder template when we can.
  if [[ "$src" == "$ENV_TEMPLATE" && -n "$brain_secret" && -n "$brain_url" ]]; then
    note="PRE-FILLED with this brain's live URL + secret — paste as-is (contains the real bearer secret)"
  fi

  printf '\n\n===== [%d/%d] %s  (owner: %s)%s =====\n\n' \
    "$i" "$n" "$dest" "$owner" "${note:+  —  $note}"

  if [[ "$src" == "$ENV_TEMPLATE" && -n "$brain_secret" && -n "$brain_url" ]]; then
    sed -e "s#https://YOUR-BRAIN.sprites.app#$brain_url#" \
        -e "s#REPLACE_WITH_TEAM_SECRET#$brain_secret#" -- "$src_path"
  else
    cat -- "$src_path"
  fi
done
