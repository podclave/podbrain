# Developing podbrain

The context you need to work **on** podbrain — how the pieces split work, the design
decisions, the expensive-to-rediscover gotchas, and the known tradeoffs. To stand one
up or use it, see [../README.md](../README.md).

Status: working, proven end-to-end on a real client→server deployment.

## The pieces (and how they split work)

- **Engine** — [`@agentmemory/agentmemory`](https://github.com/rohitg00/agentmemory) on the brain box; keyless local embeddings (`all-MiniLM-L6-v2`), BM25+vector+graph hybrid search. We don't fork it — we wrap it.
- **Gateway** (`server/gateway/app.py`) — our FastAPI front door on `:8080`: auth, `/agentmemory/*` passthrough (incl. `/mcp/*`), `/ingest` + `/docs`, `/viewer` (cookie auth + a WS proxy for the live feed), `/maintenance` (the cataloger trigger), and `/mcp` (MCP-over-HTTP — BYO Claude Code clients and claude.ai/Desktop remote connectors attach directly; no npx shim, so the shim's silent-local-fallback cannot occur on this path).
- **Client** (`client/plugin/skills/team-brain/brain.py`, stdlib only) — the deterministic **hooks** (auto-recall + passive distill) and the `file` ingest verb, over REST. Interactive memory (recall/save/curate) is the **agentmemory MCP**, *not* `brain.py`: shell hooks can't call MCP tools, so the two surfaces are split by capability.

## Key design decisions

- **Keyless everywhere.** Local embeddings on the engine; the client distiller uses the teammate's `claude -p` (subscription, not an API key); the brain cataloger uses the brain box's Claude via `AGENTMEMORY_PROVIDER=agent-sdk`.
- **Recall is a candidate menu, the model decides.** The auto-recall hook injects a wide top-k (best-first titles) and lets the client model judge relevance — **no score threshold**, because a raw hybrid score has no absolute meaning (it drifts with engine version, data volume, and query), so any floor would need per-brain tuning.
- **Dedup is the engine's native job** — Jaccard ≥0.7 supersession on write (marks the old record `isLatest=false`, bumps `version`, keeps the *newer* text). We removed our gateway-side `/remember` dedup, which kept the *older* phrasing and pre-empted it.
- **Distilled facts are tagged** (`—[auto-captured by …]` + `source:"auto-distill"` + `tags:["auto-distill"]`) distinctly from human saves (`—[saved by …]`), so machine inferences stay filterable/reviewable and aren't mistaken for vouched facts.
- **Secrets scrubbed before they leave the VM** — a regex backstop (GitHub/Slack/JWT/PEM/`scheme://user:PASS@host`/AWS/long-hex) behind the LLM "no secrets" instruction. Defense-in-depth on a *shared* brain: one leaked credential is everyone's problem.

## Lessons baked into the code (the expensive-to-rediscover stuff)

- **Hooks COMBINE across all settings sources** in Claude Code → drop hooks via managed `/etc/claude-code/managed-settings.d/` and never merge a user's `settings.json`. `autoMemoryEnabled:false` MUST be in *managed* scope to be non-overridable.
- **SessionEnd hooks get cancelled on shutdown** if slow → all distillation runs DETACHED (`setsid`) and holds a short-TTL Sprite keep-alive task (via `sprite-env`) so it survives `/exit` and auto-suspend; the task self-expires, and it's a no-op off-Sprite.
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
- **The MCP shim silently saves to a throwaway local store when the brain is unreachable** (the dangerous one). On a failed proxy call, `@agentmemory/agentmemory`'s `standalone.mjs` logs to stderr, `invalidateHandle()`, and **falls back to a local `InMemoryKV`, returning success** — so `memory_save` looks like it persisted to the team brain but didn't, and the *first* failure pins the rest of the session to local. `AGENTMEMORY_FORCE_PROXY=1` only skips the startup probe, not this runtime fallback, and **no env knob disables it**. Especially likely on our spin-down brain (a cold first call can trip it). Affects the core `IMPLEMENTED_TOOLS` (`memory_save`/`recall`/`smart_search`); the richer tools rethrow and surface errors. The real fix is upstream (a strict mode that throws instead of falling back); we mitigate, not fix, below. **Scope narrowed (2026-06):** only the Podclave fleet bundle still runs the shim; BYO clients use the gateway's `/mcp` endpoint, where a down brain is a visible tool error (verified e2e: the model reports "team brain call failed" instead of fabricated success).
- **Memory paths fail silently by design** (`except: return` — a broken brain must never block a turn), so a down brain otherwise looks identical to "nothing to recall." **Mitigation (shipped):** the recall hook doubles as a per-turn liveness probe and, on a definitive failure (auth / unreachable / non-JSON), injects a `<team-brain-status>` banner into the terminal — telling the user recall is empty *and that saves aren't persisting* (covering the deception above). Lone timeouts are tolerated for an hour (`last-ok` heartbeat) so a waking spin-down box doesn't cry wolf. Does **not** cover the capture-only failure where the client's `claude -p` OAuth has expired (recall works, distill silently stops).

- **The engine can wedge (alive but unresponsive).** Observed: the engine served fine for hours, then went silent — `/health` ReadTimeout, ~0% CPU, no error/OOM in its log. Likely the internal `ws://localhost:49134` between the REST front (`cli.mjs`) and the iii backend gets severed (a spin-down suspend/resume is the prime suspect) and never reconnects, so the REST front accepts connections but blocks forever. It doesn't self-heal. **Mitigation (shipped):** `POST /maintenance/healthcheck` deep-probes the engine and, when wedged, fires `recover-engine.sh` to restart it; run it from a ~10-min Podclave Schedule. The gateway is deliberately **not** `--needs agentmemory` — otherwise `sprite-env` would refuse to restart the engine while the gateway runs, forcing a gateway bounce to recover. (Installs created before that change kept the old needs-binding — which also silently broke the watchdog's restart — until re-running the installer, which now detects and migrates the service definition.) Decoupled, the watchdog restarts only the engine and the gateway keeps serving (it tolerates a briefly-absent engine). Upstream-worthy: the REST front should reconnect-or-die rather than hang.
- **Cold-wake vs MCP connect timeout: untested.** A suspended spin-down brain must wake within the HTTP MCP client's connect window for the FIRST call of a session. Verified working warm (local + public URL); the true suspended-wake case needs an off-box client and is deferred to the first real laptop install — if it flakes, document `MCP_TIMEOUT` guidance in the README.
- **The engine's project-scope diagnostic always nags (e.g. "14 of 15 health checks pass").** Deliberate today: brains are provisioned per project/client, so the brain itself is the project boundary and nothing we write sends the engine's `project` field. Don't let an eager model "fix" it with the suggested `infer-memory-projects` backfill — our memories aren't engine-native sessions, there's nothing to infer from. Repo-level scoping *within* a brain (stamping which repo a memory came from) is under consideration; the engine's REST `remember` is verified to persist a `project` field, so the plumbing exists when we want it.

## Ideas, not committed

- **Shrink the gateway toward viewer-only.** Now that interactive memory is the MCP, the gateway's distinct value is mostly **document ingest** and the **viewer**. A cleaner future: drop gateway-side ingest and have the **client** distill a file and feed the result into the MCP, leaving the gateway as essentially the viewer. Tradeoff: lose server-side pdf/docx/pptx extraction + sha256-idempotent originals; gain one fewer bespoke endpoint (and the language-runtime question — the proxy bits could then be Node, matching the rest of the stack).
- **Embedding write-dedup** for the cross-session paraphrase gap (local embeddings are already on the engine) — the one dedup case neither the 0.7 supersession nor MCP curation catches automatically.
- **Kill the MCP shim's silent local-save** — upstream a strict/no-fallback proxy mode (so `memory_save` *throws* when the brain is unreachable instead of degrading to local), or vendor/wrap the shim. The shipped terminal banner warns around the deception; this would remove it.
- **Detect the capture-only failure** — surface when the client's `claude -p` OAuth has expired (recall still works, so the reachability banner stays quiet while the brain silently stops learning).

## Platform assumptions (Podclave-side, not this repo)

- **Identity**: Podclave writes `~/.podclave/user-email` on Setup (drives attribution; overlays are otherwise byte-identical org-wide).
- **Delivery**: the managed overlays (`owner: root`) and the cataloger Schedule are configured in Podclave, not by the installer.
- **Environment quirk**: on a fresh sprite `$HOME` may be owned by a different user than the one the install runs as → pip cache-permission noise; the installer uses `--no-cache-dir` to stay quiet.
