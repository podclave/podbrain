# Project status & handoff

Snapshot of where podbrain stands, what's left, and the non-obvious lessons baked
into the code — so anyone (human or agent) can pick it up cold.

## What it is
A self-hosted, keyless **team brain** for Claude Code: teammates point their Claude
at one bearer-gated URL; it auto-recalls shared knowledge, auto-captures durable
facts from real work, ingests docs, and self-curates. Built on
[`@agentmemory/agentmemory`](https://github.com/rohitg00/agentmemory) (the engine)
wrapped by our FastAPI **gateway** (the value-add: auth, ingest, the browser viewer/dashboard, cataloger).
Architecture + rollout: see `README.md` (the single self-contained setup doc).

## Status: WORKING, proven end-to-end on a real client→server deployment
- Server stands up from zero: `bash server/install-brain.sh` → prints `BRAIN_URL`/`BRAIN_SECRET`. Verified on a bare sprite.
- Client = 5-overlay Podclave bundle (`client/`). Native auto-memory overtaken (`autoMemoryEnabled:false`).
- Proven: cross-session recall, cross-fact synthesis, explicit + passive capture, doc ingest, dedup, keyless cataloger.
- **Client is Python now** (`brain.py`, stdlib only) — migrated from the original bash `brain.sh` after a 3-way bash/python/elixir spike. Same CLI + hook contract; the jq/curl/flock/setsid/sed shell-outs collapse into the stdlib (json/urllib/fcntl/subprocess/re), so the distiller is legible + testable and the dep surface shrinks to `python3` + the (guarded) `claude`/`sprite-env`. The bash→python move also fixed a **stale sweep-guard** (the skip-string had drifted from the distiller prompt → risk of re-ingesting the distiller's own `claude -p` transcripts); the guard is now derived from a shared `DISTILLER_MARKER` constant embedded in the prompt, so it can't drift again.
- **Interactive memory is the agentmemory MCP now** — the client ships agentmemory's native MCP (overlay `managed-mcp.json` → `/etc/claude-code/managed-mcp.json`, root) so the agent gets the full `mcp__agentmemory__memory_*` toolset (search/save/governance-delete/consolidate/snapshot/audit). This came out of a real episode where a teammate's Claude had to reverse-engineer `/agentmemory/forget` to dedupe shared memory — MCP hands it those primitives directly. **Hooks stay** (deterministic auto-recall + passive distill; shell hooks can't call MCP tools, so they keep using `brain.py`'s REST paths). `brain.py` narrows to hooks + the `file` ingest verb. Delivery is **managed-exclusive** (only the brain MCP loads fleet-wide; `allowAllClaudeAiMcps` keeps claude.ai connectors); safe tools auto-approved via `permissions.allow`, `memory_governance_delete` left to prompt. New client dep: **node** (the `npx @agentmemory/mcp` proxy shim) + Claude Code ≥ 2.1.149.
- **Hardening pass (from a code review)** — three `brain.py` fixes: (1) **recall = a wide candidate menu, model decides** — the hook injects a generous top-k (best-first titles, default 15) under a hedged "candidates, not gospel" header and lets the client model judge relevance, pulling full detail via the MCP as needed; trivial prompts (greetings/acks/bare continuations) skip recall entirely. **No score threshold** — raw hybrid scores aren't comparable across brains, so there's no per-brain knob to tune. (2) **auto-distilled facts are tagged** distinctly (`—[auto-captured by …]` + `source:"auto-distill"` + `tags:["auto-distill"]`) vs human `—[saved by …]`, so machine inferences are filterable/reviewable and not mistaken for vouched facts. (3) **scrub hardened** — added GitHub (`gh[posru]_`), Slack (`xox[baprs]-`), JWT, PEM private-key blocks, and `scheme://user:PASS@host` (password-only redaction) to the regex backstop behind the LLM "no secrets" instruction.

## Open items (all that's left)
1. **Redeploy `client/skills/team-brain/brain.py`** to existing clients and bake into the live overlay bundle. (The overlay now invokes `python3 …/brain.py`; the managed-settings hooks were updated to match. Earlier dogfood boxes ran the older bash client.)
2. **Operator steps the installer can't do** (documented in README): set the brain Sprite to **public auth mode**; run `claude` once on the brain box so the **LLM cataloger** has an LLM (else consolidation degrades to no-op — everything else still works).
3. **Pre-go-live purge** (optional): wipe the brain to a clean slate — stop both services, `find ~/data/state_store.db -type f -delete && find ~/brain-docs -type f -delete`, restart. (No per-id REST delete exists.)
4. **Podclave-side (the platform owner's tasks):**
   - Support overlay drops to `/etc/claude-code/managed-settings.d/<name>.json` with `owner: root` (managed scope) — for hooks + `autoMemoryEnabled:false`. (Was being done by mutating `~/.claude`; managed scope is better — see git history.)
   - Write the teammate's email to `~/.podclave/user-email` on setup (drives attribution; client is identical org-wide otherwise).
   - Scheduler that does `POST <BRAIN_URL>/maintenance/run` with header `Authorization: Bearer <secret>` on a cadence (runs the cataloger; also wakes a suspended brain box). `GET /maintenance/status` to check.
   - Fix: new sprites have `$HOME` owned by `ubuntu` not `sprite` → pip cache-permission warnings (installer uses `--no-cache-dir` to stay quiet, but the root cause is a Podclave initializer bug).

## Residual / known limitations (not blocking)
- **Dedup is now the engine's native job.** Our custom gateway `/remember` dedup was **removed** — it kept the *older* phrasing and pre-empted the engine's native supersession. agentmemory supersedes near-duplicates on write at **Jaccard ≥0.7** (marks old `isLatest=false`, bumps `version`, keeps the *newer* text). Remaining gap: cross-session **paraphrases** (<0.7 lexical, e.g. "Frontend is Next.js" vs "Project Atlas: the frontend is built with Next.js") still slip past both; agents can now collapse those via the MCP (`memory_governance_delete`, prompted). agentmemory's consolidation still does **not** merge near-dups (verified) — don't rely on it. A future embedding-based write-dedup would close the paraphrase gap.
- **agentmemory's own consolidation does NOT merge near-duplicate memories** (verified) — don't rely on it for dedup.
- Distiller fidelity uses **haiku** (cheap); occasional `[]` on borderline input. Bump via `BRAIN_DISTILL_MODEL` in `.env.podclave.brain` if needed (sonnet was observed *too* conservative — test before switching).
- **Attribution is decorative, not authenticated** (accepted tradeoff). Identity is self-asserted (`~/.podclave/user-email` → git email → `$USER`) and the brain trusts a single shared `BRAIN_SECRET` bearer, so `—[saved by X]` is unverified and any compromised client box = full read/write to shared memory. Fine for a small trusted team; the real fix (per-user tokens / signed attribution) is deliberately out of scope for now.
- **Background spend on "idle" boxes** (accepted). Every `Stop` (after the 90s debounce) can spawn a background `haiku` distill on the teammate's own subscription, and the keep-alive task holds the box awake to finish. Mitigated by the debounce, single-flight flock, and the 40-char/offset gates (empty turns no-op), but idle boxes do periodic LLM work — real ongoing cost under flat billing.
- **Silent failure by design** (`except: pass` on the non-blocking memory paths) means a quietly-broken brain (expired secret, gateway down) looks identical to "nothing to recall." Future: surface a periodic health signal (e.g. `hook-sessionstart` warns once if the brain is unreachable, distinct from an empty recall) so silent rot is visible.

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
client VM: agentmemory MCP (managed-mcp.json → npx @agentmemory/mcp proxy shim:
  interactive recall/save/curate) + brain.py (hooks: auto-recall/stop/sessionend/
  sessionstart/distill, + file ingest) + managed-settings.d (hooks + MCP-tool perms)
        │ HTTPS + bearer  (MCP → /agentmemory/mcp/* ; hooks/file → REST)
brain box: gateway (server/gateway/app.py, :8080 public) — auth, /agentmemory/* passthrough
  (incl. /agentmemory/mcp/* + /livez), /ingest, /docs, /viewer, /maintenance/run+status
        ├─ agentmemory engine (:3111 internal, local embeddings, BM25+vector+graph)
        └─ viewer (:3113)
  data: ~/data (engine), ~/brain-docs (originals + manifest.db), ~/.agentmemory/.env (config+secret)
```

## Future directions (ideas, not committed)
- **Shrink the gateway toward viewer-only.** Now that interactive memory is the MCP,
  the gateway's distinct value is mostly **document ingest** (`/ingest`, `/docs`) and
  the **viewer** proxy (+ auth + the cataloger trigger). A cleaner future: drop
  gateway-side ingest and instead have the **client distill a file and feed the
  result into the MCP tools** (`memory_save`/`file`-style), at which point the gateway
  is essentially just the **viewer** (now browser-openable — cookie login at
  `<BRAIN_URL>/viewer?key=<secret>` + a gateway WS proxy for its live feed, shipped in
  #2). Tradeoff: lose server-side pdf/docx/pptx extraction +
  sha256-idempotent originals; gain one fewer bespoke endpoint.
- **Embedding write-dedup** for the cross-session paraphrase gap (local embeddings are
  already on the engine) — the one dedup case neither the engine's 0.7 supersession
  nor the MCP curation catches automatically.

## Verify a running brain
```bash
curl <BRAIN_URL>/healthz
curl -H "Authorization: Bearer <secret>" <BRAIN_URL>/agentmemory/health
curl -H "Authorization: Bearer <secret>" <BRAIN_URL>/agentmemory/memories?limit=20
```
