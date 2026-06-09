#!/usr/bin/env bash
# install-brain.sh — stand up a complete podbrain SERVER on a fresh Sprite.
# Idempotent; safe to re-run. From a checkout:  bash server/install-brain.sh
#
# Provisions: agentmemory engine (keyless local embeddings) + ~/.agentmemory/.env
# + the FastAPI gateway + two Sprite services (agentmemory :3111 internal,
# team-brain gateway :8080 public). Prints the BRAIN_URL + BRAIN_SECRET to drop
# into the client overlay. Client onboarding ships separately — see ../client/.
set -euo pipefail
log(){ printf '\033[1;36m[brain]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[brain] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 0. preflight: required tooling on the box ------------------------------
for t in node npm python3 openssl curl sprite-env; do
  command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"
done
python3 -c 'import venv' 2>/dev/null || die "python3 venv module not available"
NODE_BIN="$(command -v node)"
TEAM_ID="${TEAM_ID:-your-team}"
AM_DIR="$HOME/.agentmemory"; GW_DIR="$HOME/brain-gateway"; DOCS_DIR="$HOME/brain-docs"

# --- 1. agentmemory engine ---------------------------------------------------
if ! npm ls -g @agentmemory/agentmemory >/dev/null 2>&1; then
  log "installing @agentmemory/agentmemory"; npm install -g @agentmemory/agentmemory@latest
else log "agentmemory already installed"; fi
AM_CLI="$(npm root -g)/@agentmemory/agentmemory/dist/cli.mjs"
[ -f "$AM_CLI" ] || die "agentmemory cli not found at $AM_CLI"

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
log "configured $ENV_FILE (TEAM_ID=$TEAM_ID, keyless local embeddings)"

# --- 3. gateway (copy from repo) + venv -------------------------------------
mkdir -p "$GW_DIR" "$DOCS_DIR"
cp "$HERE/gateway/app.py" "$HERE/gateway/requirements.txt" "$HERE/gateway/recover-engine.sh" "$GW_DIR/"
chmod +x "$GW_DIR/recover-engine.sh"
[ -d "$GW_DIR/.venv" ] || { log "creating gateway venv"; python3 -m venv "$GW_DIR/.venv"; }
log "installing gateway deps"
"$GW_DIR/.venv/bin/pip" install -q --no-cache-dir --upgrade pip >/dev/null
"$GW_DIR/.venv/bin/pip" install -q --no-cache-dir -r "$GW_DIR/requirements.txt"

# --- 4. sprite services ------------------------------------------------------
svc_exists(){ sprite-env services get "$1" >/dev/null 2>&1; }
if svc_exists agentmemory; then log "restart agentmemory"; sprite-env services restart agentmemory >/dev/null
else
  log "create service: agentmemory (internal :3111)"
  sprite-env services create agentmemory --cmd "$NODE_BIN" --args "$AM_CLI,--port,3111" \
    --env "HOME=$HOME" --dir "$HOME" --no-stream >/dev/null
fi
if svc_exists team-brain; then log "restart team-brain"; sprite-env services restart team-brain >/dev/null
else
  log "create service: team-brain gateway (public :8080)"
  sprite-env services create team-brain --cmd "$GW_DIR/.venv/bin/python" \
    --args "-m,uvicorn,app:app,--host,0.0.0.0,--port,8080" \
    --env "HOME=$HOME,AGENTMEMORY_SECRET=$SECRET" \
    --dir "$GW_DIR" --needs agentmemory --http-port 8080 --no-stream >/dev/null
fi

# --- 5. wait for health + report --------------------------------------------
log "waiting for gateway to come up..."
ok=0
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:8080/healthz 2>/dev/null || true)"
  [ "$code" = "200" ] && { ok=1; break; }
  sleep 1
done
[ "$ok" = "1" ] || die "gateway did not become healthy on :8080 (check: sprite-env services get team-brain)"
URL="$(sprite-env info | python3 -c 'import sys,json;print(json.load(sys.stdin).get("sprite_url",""))' 2>/dev/null)"

cat <<EOF

=========================================================================
  podbrain server is UP.
  ---------------------------------------------------------------------
  export BRAIN_URL="${URL:-<run: sprite-env info>}"
  export BRAIN_SECRET="$SECRET"
  ---------------------------------------------------------------------
  Next:
   1. Ensure this Sprite is in PUBLIC auth mode (bearer is the gatekeeper).
   2. Render the client overlays:  bash client/overlay_instructions.sh
      (#3 .env.podclave.brain is pre-filled with the values above), then
      paste each block into the Podclave team-brain bundle.
   3. Add two Podclave Schedules (header 'Authorization: Bearer $SECRET'):
        - cataloger:  POST ${URL:-<url>}/maintenance/run          (e.g. hourly)
        - watchdog:   POST ${URL:-<url>}/maintenance/healthcheck  (e.g. every 10m)
      Full guide: ./README.md
  Verify:  curl -H "Authorization: Bearer $SECRET" ${URL:-<url>}/agentmemory/health
=========================================================================
EOF
