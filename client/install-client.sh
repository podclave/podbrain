#!/usr/bin/env bash
# install-client.sh — wire a teammate's Claude Code into the team brain.
# Intended to run per-VM (e.g. from the Podclave org overlay). Idempotent.
#
# Required env: BRAIN_URL, BRAIN_SECRET
# Optional:     MANAGED_DIR (default /etc/claude-code/managed-settings.d)
#
# Installs:
#   ~/.claude/skills/team-brain/         (skill + helper + hooks + distiller)
#   ~/.claude/skills/team-brain/brain.env (rendered from BRAIN_URL/BRAIN_SECRET)
#   $MANAGED_DIR/20-team-brain.json      (auto-recall + capture hooks, org-wide)
set -euo pipefail
log(){ printf '\033[1;36m[brain-client]\033[0m %s\n' "$*"; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${BRAIN_URL:?set BRAIN_URL}"; : "${BRAIN_SECRET:?set BRAIN_SECRET}"
MANAGED_DIR="${MANAGED_DIR:-/etc/claude-code/managed-settings.d}"

DEST="$HOME/.claude/skills/team-brain"
mkdir -p "$DEST"
cp -r "$HERE/skills/team-brain/." "$DEST/"
chmod +x "$DEST/brain.sh" "$DEST/hooks/"*.sh "$DEST/capture/"*.sh 2>/dev/null || true

cat > "$DEST/brain.env" <<EOF
# rendered by install-client.sh — identical org-wide; identity via ~/.podclave/user-email
BRAIN_URL="$BRAIN_URL"
BRAIN_SECRET="$BRAIN_SECRET"
BRAIN_USER=""
EOF
chmod 600 "$DEST/brain.env"
log "installed skill bundle to $DEST"

# Hooks combine across settings sources, so this never touches the user's settings.json.
if mkdir -p "$MANAGED_DIR" 2>/dev/null && [ -w "$MANAGED_DIR" ]; then
  cp "$HERE/managed-settings.d/20-team-brain.json" "$MANAGED_DIR/20-team-brain.json"
  log "installed hooks to $MANAGED_DIR/20-team-brain.json"
else
  log "WARN: cannot write $MANAGED_DIR (need root). Place managed-settings.d/20-team-brain.json there via the overlay."
fi
log "done. verify:  bash $DEST/brain.sh health"
