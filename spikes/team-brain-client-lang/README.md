# Spike: should the client be bash, python, or elixir?

**Status: exploration / decision aid. Nothing in production changed by this PR.**
This dir holds two faithful ports of the team-brain client plus a test harness, so
the bash-vs-python-vs-elixir choice can be judged from real code and real numbers
rather than assertion. See [`SPIKE-NOTES.md`](./SPIKE-NOTES.md) for the findings,
the benchmark table, and the recommendation.

The production client remains `client/skills/team-brain/brain.sh` — untouched.

## Files
- `brain.py`  — single-file client, **stdlib only** (urllib/json/fcntl/subprocess/re).
- `brain.exs` — single-file client, **zero deps** (OTP 28 `:json`/`:httpc`/`:crypto`).
- `mockbrain.py` — a ~50-line stand-in for the gateway, enough to validate equivalence.

All three implement the identical CLI + hook contract:
`recall | remember | file | health | distill | hook-{recall,stop,sessionend,sessionstart}`.

## Reproduce the comparison

```sh
cd spikes/team-brain-client-lang
cp ../../client/skills/team-brain/brain.sh .          # bring in the reference client

# 1. start the mock gateway
setsid python3 mockbrain.py >/dev/null 2>&1 &
export BRAIN_URL=http://127.0.0.1:8099 BRAIN_SECRET=testsecret BRAIN_USER=tester@example.com

# 2. functional equivalence (same store, same output)
bash    brain.sh  remember "cache is redis 7 cluster" fact
python3 brain.py  recall   "redis"
elixir  brain.exs recall   "redis"

# 3. distill pipeline with a fake `claude` on PATH (emits a JSON array incl. a
#    secret to scrub) — proves scrub + feedback-loop strip + same-session exclusion
mkdir -p fakebin && cat > fakebin/claude <<'SH'
#!/usr/bin/env bash
cat >/tmp/last_distill_prompt.txt
printf '%s\n' '[{"content":"the prod gateway is Kong on port 8000","type":"fact"},{"content":"token is sk-ant-abcdef123456789","type":"lesson"}]'
SH
chmod +x fakebin/claude
PATH="$PWD/fakebin:$PATH" python3 brain.py distill demoSID /path/to/a/transcript.jsonl

# 4. benchmark startup / hot paths: see SPIKE-NOTES.md for the method + results
pkill -f mockbrain.py
```

## TL;DR recommendation
- Extending the distiller / want clean, portable, opensource-ready → **python**.
- Leaving it alone (proven, Sprite-only) → **keep bash** (but fix the stale
  sweep-guard noted in SPIKE-NOTES).
- **Not elixir** for this client — ~3–4× python / 20–100× bash per invocation, and
  it shells out to the same `setsid`/`flock` bash uses anyway.
