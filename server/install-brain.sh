#!/usr/bin/env bash
# install-brain.sh — stand up a complete podbrain SERVER on a fresh Sprite.
# Idempotent; safe to re-run. Run from a checkout:  bash server/install-brain.sh
#
# Provisions:
#   1. agentmemory (npm -g)        — memory engine, keyless local embeddings
#   2. ~/.agentmemory/.env         — local embeddings, bearer secret, team mode,
#                                     keyless LLM cataloger (agent-sdk)
#   3. ~/brain-gateway             — FastAPI front door (copied from this repo)
#   4. Sprite services             — agentmemory (internal :3111) + team-brain (:8080)
#
# Client onboarding ships separately via the Podclave overlay — see ../client/.
set -euo pipefail
log(){ printf '\033[1;36m[brain]\033[0m %s\n' "$*"; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TEAM_ID="${TEAM_ID:-your-team}"
NODE_BIN="$(command -v node)"
AM_DIR="$HOME/.agentmemory"
GW_DIR="$HOME/brain-gateway"
DOCS_DIR="$HOME/brain-docs"

# --- 1. agentmemory engine ---------------------------------------------------
if ! npm ls -g @agentmemory/agentmemory >/dev/null 2>&1; then
  log "installing @agentmemory/agentmemory"; npm install -g @agentmemory/agentmemory@latest
else log "agentmemory already installed"; fi
AM_CLI="$(npm root -g)/@agentmemory/agentmemory/dist/cli.mjs"

# --- 2. config + bearer secret ----------------------------------------------
mkdir -p "$AM_DIR"
[ -f "$AM_DIR/.env" ] || "$NODE_BIN" "$AM_CLI" init >/dev/null 2>&1 || true
if [ ! -f "$AM_DIR/team_secret.txt" ]; then
  log "generating bearer secret"; openssl rand -hex 24 > "$AM_DIR/team_secret.txt"; chmod 600 "$AM_DIR/team_secret.txt"
fi
SECRET="$(cat "$AM_DIR/team_secret.txt")"
ENV_FILE="$AM_DIR/.env"; touch "$ENV_FILE"
sed -i '/# >>> team-brain managed >>>/,/# <<< team-brain managed <<</d' "$ENV_FILE"
cat >> "$ENV_FILE" <<EOF
# >>> team-brain managed >>>
EMBEDDING_PROVIDER=local
AGENTMEMORY_SECRET=$SECRET
AGENTMEMORY_TOOLS=all
TEAM_MODE=shared
TEAM_ID=$TEAM_ID
# keyless LLM cataloger (Claude subscription on this box)
CONSOLIDATION_ENABLED=true
AGENTMEMORY_ALLOW_AGENT_SDK=true
AGENTMEMORY_PROVIDER=agent-sdk
# <<< team-brain managed <<<
EOF
log "configured $ENV_FILE (TEAM_ID=$TEAM_ID)"

# --- 3. gateway (copy from repo) + venv -------------------------------------
mkdir -p "$GW_DIR" "$DOCS_DIR"
cp "$HERE/gateway/app.py" "$HERE/gateway/requirements.txt" "$GW_DIR/"
[ -d "$GW_DIR/.venv" ] || { log "creating gateway venv"; python3 -m venv "$GW_DIR/.venv"; }
log "installing gateway deps"
"$GW_DIR/.venv/bin/pip" install -q --upgrade pip >/dev/null
"$GW_DIR/.venv/bin/pip" install -q -r "$GW_DIR/requirements.txt"

# --- 4. sprite services ------------------------------------------------------
svc_exists(){ sprite-env services get "$1" >/dev/null 2>&1; }
if svc_exists agentmemory; then log "restart agentmemory"; sprite-env services restart agentmemory
else
  log "create service: agentmemory (internal :3111)"
  sprite-env services create agentmemory --cmd "$NODE_BIN" --args "$AM_CLI,--port,3111" \
    --env "HOME=$HOME" --dir "$HOME" --no-stream
fi
if svc_exists team-brain; then log "restart team-brain"; sprite-env services restart team-brain
else
  log "create service: team-brain gateway (public :8080)"
  sprite-env services create team-brain --cmd "$GW_DIR/.venv/bin/python" \
    --args "-m,uvicorn,app:app,--host,0.0.0.0,--port,8080" \
    --env "HOME=$HOME,AGENTMEMORY_SECRET=$SECRET" \
    --dir "$GW_DIR" --needs agentmemory --http-port 8080 --no-stream
fi
sleep 4
log "secret: $SECRET"
log "done. verify:  curl -H 'Authorization: Bearer \$SECRET' \$(sprite url)/healthz"
log "give teammates this secret + the public URL for client onboarding (../client/)."
