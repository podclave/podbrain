#!/usr/bin/env bash
# recover-engine.sh — health-check + self-heal for the agentmemory engine.
#
# The engine can wedge: alive but unresponsive (e.g. its internal WS to the iii backend
# severed by a spin-down suspend/resume), after which every gateway call ReadTimeouts.
# This probes the engine and, only if it's wedged, cycles it — working around the
# team-brain `needs agentmemory` dependency (sprite-env won't stop a service a running
# service needs) by stopping the gateway, restarting the engine, then bringing the
# gateway back. Idempotent and safe on a cadence: a no-op when the engine is healthy.
#
# Used two ways: the gateway spawns it DETACHED from POST /maintenance/healthcheck, or
# run it directly (cron / a command-capable scheduler) — the direct path is more robust
# since it doesn't depend on the gateway being up.
set -u
LOG="${BRAIN_RECOVER_LOG:-$HOME/.agentmemory/recover.log}"
SEC_FILE="$HOME/.agentmemory/team_secret.txt"
say() { echo "$(date -u +%FT%TZ) recover: $*" >>"$LOG" 2>&1; }
engine_ok() {
  curl -sf -m 4 -H "Authorization: Bearer $(cat "$SEC_FILE" 2>/dev/null)" \
    http://localhost:3111/agentmemory/health >/dev/null 2>&1
}

engine_ok && exit 0   # healthy → nothing to do (the common case)

# Single-flight: don't let overlapping schedule ticks stack restarts.
exec 9>"/tmp/brain-recover.lock"
flock -n 9 || { say "already recovering, skip"; exit 0; }
engine_ok && { say "recovered before lock; skip"; exit 0; }   # re-check under lock

sleep 2   # let the triggering HTTP response flush before the gateway goes down
say "engine wedged — cycling (stop gateway → restart engine → start gateway)"
sprite-env services stop team-brain     >>"$LOG" 2>&1 || say "WARN: stop team-brain failed"
sprite-env services restart agentmemory >>"$LOG" 2>&1 || say "WARN: restart agentmemory failed"
for i in $(seq 1 30); do
  engine_ok && { say "engine healthy after ~$((i * 2))s"; break; }
  sleep 2
done
engine_ok || say "WARN: engine still not answering after wait; starting gateway anyway"
sprite-env services start team-brain    >>"$LOG" 2>&1 || say "WARN: start team-brain failed"
say "done"
