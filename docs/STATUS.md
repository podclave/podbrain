# Project status & handoff

Snapshot of where podbrain stands, what's left, and the non-obvious lessons baked
into the code — so anyone (human or agent) can pick it up cold.

## What it is
A self-hosted, keyless **team brain** for Claude Code: teammates point their Claude
at one bearer-gated URL; it auto-recalls shared knowledge, auto-captures durable
facts from real work, ingests docs, and self-curates. Built on
[`@agentmemory/agentmemory`](https://github.com/rohitg00/agentmemory) (the engine)
wrapped by our FastAPI **gateway** (the value-add: auth, ingest, dedup, cataloger).
Architecture + rollout: see `README.md`, `docs/ROLLOUT.md`, `client/README.md`.

## Status: WORKING, proven end-to-end on a real client→server deployment
- Server stands up from zero: `bash server/install-brain.sh` → prints `BRAIN_URL`/`BRAIN_SECRET`. Verified on a bare sprite.
- Client = 4-overlay Podclave bundle (`client/`). Native auto-memory overtaken (`autoMemoryEnabled:false`).
- Proven: cross-session recall, cross-fact synthesis, explicit + passive capture, doc ingest, dedup, keyless cataloger.

## Open items (all that's left)
1. **Redeploy `client/skills/team-brain/brain.sh`** (latest, commit history thru the "quality pass B") to existing clients and bake into the live overlay bundle. (Earlier client boxes ran older brain.sh during the dogfood.)
2. **Operator steps the installer can't do** (documented in ROLLOUT): set the brain Sprite to **public auth mode**; run `claude` once on the brain box so the **LLM cataloger** has an LLM (else consolidation degrades to no-op — everything else still works).
3. **Pre-go-live purge** (optional): wipe the brain to a clean slate — stop both services, `find ~/data/state_store.db -type f -delete && find ~/brain-docs -type f -delete`, restart. (No per-id REST delete exists.)
4. **Podclave-side (the platform owner's tasks):**
   - Support overlay drops to `/etc/claude-code/managed-settings.d/<name>.json` with `owner: root` (managed scope) — for hooks + `autoMemoryEnabled:false`. (Was being done by mutating `~/.claude`; managed scope is better — see the snippet in git history / ROLLOUT.)
   - Write the teammate's email to `~/.podclave/user-email` on setup (drives attribution; client is identical org-wide otherwise).
   - Scheduler that does `POST <BRAIN_URL>/maintenance/run` with header `Authorization: Bearer <secret>` on a cadence (runs the cataloger; also wakes a suspended brain box). `GET /maintenance/status` to check.
   - Fix: new sprites have `$HOME` owned by `ubuntu` not `sprite` → pip cache-permission warnings (installer uses `--no-cache-dir` to stay quiet, but the root cause is a Podclave initializer bug).

## Residual / known limitations (not blocking)
- **Cross-session paraphrase dedup**: gateway dedup is lexical (token-set Jaccard ≥0.8) → catches exact/near-exact; loose paraphrases across different sessions can still double up. The dominant explicit+passive same-session dup IS handled (distiller excludes same-session `brain.sh remember` calls). A future embedding-based dedup would close the rest.
- **agentmemory's own consolidation does NOT merge near-duplicate memories** (verified) — don't rely on it for dedup.
- Distiller fidelity uses **haiku** (cheap); occasional `[]` on borderline input. Bump via `BRAIN_DISTILL_MODEL` in `.env.podclave.brain` if needed (sonnet was observed *too* conservative — test before switching).

## Hard-won lessons baked into the code (the expensive-to-rediscover stuff)
- **Hooks COMBINE across all settings sources** in Claude Code → drop hooks via managed `/etc/claude-code/managed-settings.d/` and never merge a user's `settings.json`. `autoMemoryEnabled:false` MUST be in *managed* scope to be non-overridable.
- **SessionEnd hooks get cancelled on shutdown** if slow → all distillation runs DETACHED (`setsid`) and holds a Sprite keep-alive task so it survives `/exit` and auto-suspend. Keep-alive uses `sprite-env curl /v1/tasks` (fixed name `brain-capture`, 1m TTL upsert; no-op off-Sprite).
- **`claude -p` writes its own transcript** → the SessionStart sweep must skip transcripts containing the distiller prompt, or it re-ingests its own output.
- **Recursion guard**: distillation runs `claude -p` with `BRAIN_DISTILLER=1`; every hook checks it and exits (verified env inherits into child-session hooks).
- **Prompt hijack**: a transcript that looks like a question makes a weak model *answer it* instead of extracting → hard-delimit with `===TRANSCRIPT===` + anti-hijack directive.
- **Feedback loop**: auto-recalled context lands in the transcript → strip `<team-brain-context>` blocks and `isMeta` (skill-load) entries before distilling, or the brain re-ingests what it recalled.
- **Sweep backfill**: a re-pointed/reused client would backfill old transcripts into a new brain → SessionStart sweep gates on a per-client `~/.claude/.brain/since` marker (only newer transcripts eligible).
- **flock** for per-session single-flight (auto-releases on crash → no stale locks). A bash `RETURN` trap for cleanup leaks across functions under `set -u` — don't.
- **Keyless** everywhere: local embeddings (`all-MiniLM-L6-v2`) on the engine; the **client distiller** uses the teammate's `claude -p`; the **brain cataloger** uses the brain box's Claude via `AGENTMEMORY_PROVIDER=agent-sdk`. No API keys.
- **Ops gotcha**: `zsh` aborts a whole `rm glob1 glob2` line if any glob is empty (`nomatch`) — use `find -delete`.

## Architecture quick-map
```
client VM: skills/team-brain/brain.sh (one file: recall/remember/file/health +
  hook-recall/hook-stop/hook-sessionend/hook-sessionstart + distill) + managed-settings.d hooks
        │ HTTPS + bearer
brain box: gateway (server/gateway/app.py, :8080 public) — auth, /agentmemory/* passthrough
  (with write-time dedup on /remember), /ingest, /docs, /viewer, /maintenance/run+status
        ├─ agentmemory engine (:3111 internal, local embeddings, BM25+vector+graph)
        └─ viewer (:3113)
  data: ~/data (engine), ~/brain-docs (originals + manifest.db), ~/.agentmemory/.env (config+secret)
```

## Verify a running brain
```bash
curl <BRAIN_URL>/healthz
curl -H "Authorization: Bearer <secret>" <BRAIN_URL>/agentmemory/health
curl -H "Authorization: Bearer <secret>" <BRAIN_URL>/agentmemory/memories?limit=20
```
