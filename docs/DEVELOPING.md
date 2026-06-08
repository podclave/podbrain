# Developing podbrain

The context you need to work **on** podbrain — how the pieces split work, the design
decisions, the expensive-to-rediscover gotchas, and the known tradeoffs. To stand one
up or use it, see [../README.md](../README.md).

Status: working, proven end-to-end on a real client→server deployment.

## The pieces (and how they split work)

- **Engine** — [`@agentmemory/agentmemory`](https://github.com/rohitg00/agentmemory) on the brain box; keyless local embeddings (`all-MiniLM-L6-v2`), BM25+vector+graph hybrid search. We don't fork it — we wrap it.
- **Gateway** (`server/gateway/app.py`) — our FastAPI front door on `:8080`: auth, `/agentmemory/*` passthrough (incl. `/mcp/*`), `/ingest` + `/docs`, `/viewer` (cookie auth + a WS proxy for the live feed), `/maintenance` (the cataloger trigger).
- **Client** (`client/skills/team-brain/brain.py`, stdlib only) — the deterministic **hooks** (auto-recall + passive distill) and the `file` ingest verb, over REST. Interactive memory (recall/save/curate) is the **agentmemory MCP**, *not* `brain.py`: shell hooks can't call MCP tools, so the two surfaces are split by capability.

## Key design decisions

- **Keyless everywhere.** Local embeddings on the engine; the client distiller uses the teammate's `claude -p` (subscription, not an API key); the brain cataloger uses the brain box's Claude via `AGENTMEMORY_PROVIDER=agent-sdk`.
- **Recall is a candidate menu, the model decides.** The auto-recall hook injects a wide top-k (best-first titles) and lets the client model judge relevance — **no score threshold**, because a raw hybrid score has no absolute meaning (it drifts with engine version, data volume, and query), so any floor would need per-brain tuning.
- **Dedup is the engine's native job** — Jaccard ≥0.7 supersession on write (marks the old record `isLatest=false`, bumps `version`, keeps the *newer* text). We removed our gateway-side `/remember` dedup, which kept the *older* phrasing and pre-empted it.
- **Distilled facts are tagged** (`—[auto-captured by …]` + `source:"auto-distill"` + `tags:["auto-distill"]`) distinctly from human saves (`—[saved by …]`), so machine inferences stay filterable/reviewable and aren't mistaken for vouched facts.
- **Secrets scrubbed before they leave the VM** — a regex backstop (GitHub/Slack/JWT/PEM/`scheme://user:PASS@host`/AWS/long-hex) behind the LLM "no secrets" instruction. Defense-in-depth on a *shared* brain: one leaked credential is everyone's problem.

## Lessons baked into the code (the expensive-to-rediscover stuff)

- **Hooks COMBINE across all settings sources** in Claude Code → drop hooks via managed `/etc/claude-code/managed-settings.d/` and never merge a user's `settings.json`. `autoMemoryEnabled:false` MUST be in *managed* scope to be non-overridable.
- **SessionEnd hooks get cancelled on shutdown** if slow → all distillation runs DETACHED (`setsid`) and holds a Sprite keep-alive task so it survives `/exit` and auto-suspend. Keep-alive: `sprite-env curl /v1/tasks` (fixed name `brain-capture`, 1m-TTL upsert; no-op off-Sprite).
- **`claude -p` writes its own transcript** → the SessionStart sweep must skip transcripts containing the distiller prompt, or it re-ingests its own output. The skip-guard is derived from a shared `DISTILLER_MARKER` constant embedded in the prompt, so the two can't drift.
- **Recursion guard**: distillation runs `claude -p` with `BRAIN_DISTILLER=1`; every hook checks it and exits (env inherits into child-session hooks).
- **Prompt hijack**: a transcript that looks like a question makes a weak model *answer it* instead of extracting → hard-delimit with `===TRANSCRIPT===` + an anti-hijack directive.
- **Feedback loop**: auto-recalled context lands in the transcript → strip `<team-brain-context>` blocks and `isMeta` (skill-load) entries before distilling, or the brain re-ingests what it recalled.
- **Sweep backfill**: a re-pointed/reused client would backfill old transcripts into a new brain → the SessionStart sweep gates on a per-client `~/.claude/.brain/since` marker (only newer transcripts eligible).
- **flock** for per-session single-flight (auto-releases on crash → no stale locks).
- **`zsh` aborts a whole `rm glob1 glob2` line** if any glob is empty (`nomatch`) → use `find -delete` (the installer does).

## Known limitations & tradeoffs (deliberate, not bugs)

- **Cross-session paraphrases slip past dedup.** The engine's 0.7 supersession only catches lexical near-duplicates; "Frontend is Next.js" vs "Project Atlas: the frontend is built with Next.js" both survive. Agents can collapse them via the MCP (`memory_governance_delete`, prompted). The engine's consolidation does **not** merge near-dups (verified) — don't rely on it.
- **No per-id REST delete** — wiping the brain to a clean slate means stopping both services and `find ~/data/state_store.db -type f -delete && find ~/brain-docs -type f -delete`, then restart.
- **Distiller fidelity uses `haiku`** (cheap) → occasional `[]` on borderline input. Bump via `BRAIN_DISTILL_MODEL` in `.env.podclave.brain` if needed (sonnet was observed *too* conservative — test before switching).
- **Attribution is decorative, not authenticated** (accepted). Identity is self-asserted (`~/.podclave/user-email` → git email → `$USER`) and the brain trusts a single shared `BRAIN_SECRET`, so `—[saved by X]` is unverified and any compromised client box = full read/write to shared memory. Fine for a small trusted team; per-user tokens / signed attribution are deliberately out of scope.
- **Background spend on "idle" boxes** (accepted). Every `Stop` (after the 90s debounce) can spawn a background `haiku` distill on the teammate's own subscription, and the keep-alive holds the box awake to finish. Mitigated by the debounce, single-flight flock, and the 40-char/offset gates (empty turns no-op), but idle boxes do periodic LLM work.
- **Silent failure by design** (`except: pass` on the non-blocking memory paths) → a quietly-broken brain (expired secret, gateway down) looks identical to "nothing to recall." The fix would be a periodic health signal (e.g. `hook-sessionstart` warns once if the brain is unreachable, distinct from an empty recall) so silent rot is visible.

## Ideas, not committed

- **Shrink the gateway toward viewer-only.** Now that interactive memory is the MCP, the gateway's distinct value is mostly **document ingest** and the **viewer**. A cleaner future: drop gateway-side ingest and have the **client** distill a file and feed the result into the MCP, leaving the gateway as essentially the viewer. Tradeoff: lose server-side pdf/docx/pptx extraction + sha256-idempotent originals; gain one fewer bespoke endpoint (and the language-runtime question — the proxy bits could then be Node, matching the rest of the stack).
- **Embedding write-dedup** for the cross-session paraphrase gap (local embeddings are already on the engine) — the one dedup case neither the 0.7 supersession nor MCP curation catches automatically.
- **Surface a health signal** (see "silent failure" above) so a dead brain stops looking like an empty one.

## Platform assumptions (Podclave-side, not this repo)

- **Identity**: Podclave writes `~/.podclave/user-email` on Setup (drives attribution; overlays are otherwise byte-identical org-wide).
- **Delivery**: the managed overlays (`owner: root`) and the cataloger Schedule are configured in Podclave, not by the installer.
- **Known bug**: new sprites have `$HOME` owned by `ubuntu`, not `sprite` (a Podclave initializer issue) → pip cache-permission noise; the installer uses `--no-cache-dir` to stay quiet.
