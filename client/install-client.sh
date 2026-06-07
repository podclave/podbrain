#!/usr/bin/env bash
# install-client.sh — wire a teammate's Claude Code into the team brain.
#
# By default this installs ONLY the $HOME pieces (skill bundle + brain.env).
# The hooks file at /etc/claude-code/managed-settings.d/ is placed by the
# Podclave org overlay (owner: root) — see docs/ROLLOUT.md. Pass --with-hooks
# to also install it locally (useful for a manual dogfood VM without the overlay;
# requires write access to MANAGED_DIR).
#
# Required env: BRAIN_URL, BRAIN_SECRET
# Optional:     MANAGED_DIR (default /etc/claude-code/managed-settings.d)
set -euo pipefail
log(){ printf '\033[1;36m[brain-client]\033[0m %s\n' "$*"; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${BRAIN_URL:?set BRAIN_URL}"; : "${BRAIN_SECRET:?set BRAIN_SECRET}"
WITH_HOOKS=0; [ "${1:-}" = "--with-hooks" ] && WITH_HOOKS=1
MANAGED_DIR="${MANAGED_DIR:-/etc/claude-code/managed-settings.d}"

DEST="$HOME/.claude/skills/team-brain"
mkdir -p "$DEST"
cp "$HERE/skills/team-brain/SKILL.md" "$HERE/skills/team-brain/brain.sh" "$DEST/"
chmod +x "$DEST/brain.sh" 2>/dev/null || true

# Mirror the overlay model: config lives in ~/.env.podclave.brain (brain.sh reads it).
cat > "$HOME/.env.podclave.brain" <<EOF
export BRAIN_URL="$BRAIN_URL"
export BRAIN_SECRET="$BRAIN_SECRET"
EOF
chmod 600 "$HOME/.env.podclave.brain"
log "installed skill bundle to $DEST + config to ~/.env.podclave.brain"

if [ "$WITH_HOOKS" = "1" ]; then
  if mkdir -p "$MANAGED_DIR" 2>/dev/null && [ -w "$MANAGED_DIR" ]; then
    cp "$HERE/managed-settings.d/20-team-brain.json" "$MANAGED_DIR/20-team-brain.json"
    log "installed hooks to $MANAGED_DIR/20-team-brain.json"
  else
    log "ERROR: --with-hooks set but cannot write $MANAGED_DIR (need root)"; exit 1
  fi
else
  log "skipped /etc hooks (overlay places them; pass --with-hooks for manual setup)"
fi
log "done. verify:  bash $DEST/brain.sh health"
