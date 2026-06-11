# BYO Client: Gateway MCP Endpoint + team-brain Plugin — Design Spec

**Date:** 2026-06-10
**Status:** approved direction (research complete; see `tmp/CLIENT_INSTALL_OPTIONS.txt` — a local-only working log on the dev box — for the full verified-facts trail)
**Plans:** `docs/superpowers/plans/2026-06-10-gateway-mcp-endpoint.md` (build first), `docs/superpowers/plans/2026-06-10-team-brain-plugin.md`

## Problem

Today the podbrain client ships only as a 5-overlay Podclave fleet bundle. Anyone
with their own Claude Code (laptop, non-Podclave VM) has no install path, and the
interactive memory surface — the `npx @agentmemory/mcp` stdio shim — has a
dangerous failure mode: on any failed proxy call it silently falls back to a local
throwaway store and **reports success**, so saves look persisted to the team brain
but aren't.

## Goals

1. **One install path for any Claude Code**: a Claude Code plugin bundling the
   skill, the 4 hooks, and the MCP server. Two commands + two config values.
2. **Kill the silent-local-save failure mode** for these users: the brain itself
   serves MCP over HTTP, so there is no client-side shim and no local fallback —
   a down brain is a visible error.
3. **Per-project brain attachment** (compliance requirement): different projects
   on one machine can attach to different brains (per-client MSAs), with the
   active brain visible in-session and containment by default.
4. **Every Claude surface**: the same HTTP MCP endpoint doubles as a remote
   connector for claude.ai / Claude Desktop / Cowork (interactive memory, no
   plugin).

## Non-goals (explicitly deferred)

- **Fleet/Podclave migration to the plugin** (managed `enabledPlugins`,
  allowlists vs `managed-mcp.json` exclusivity). The 5-overlay bundle stays
  as-is; revisit from first principles after the plugin is proven.
- **Knowledge-repo integration** (durable git store, memory→doc citations,
  folder auto-ingest) — Ben's workstream; the plugin stays multi-skill-friendly
  so a knowledge-repo skill can slot in later.
- **Viewer "seed data" button**: investigated — the demo seeder writes via plain
  observation POSTs (no dedicated route to block at the gateway). Needs an
  upstream fix or HTML-level hiding; tracked as a follow-up nit, not in these plans.

## Design

### Part 1 — Gateway MCP endpoint (`POST /mcp`)

A stateless [MCP Streamable HTTP] endpoint implemented directly in the FastAPI
gateway (new module `server/gateway/mcp_endpoint.py`, no new dependencies —
deliberately NOT the `mcp` pip package: our tools are plain request/response, a
hand-rolled JSON-RPC handler is ~150 lines, and we avoid a fast-moving dep).

- **Protocol**: `initialize` (echo client's `protocolVersion` if known, else
  `2025-06-18`; capabilities `{"tools": {}}`), `notifications/*` → HTTP 202,
  `ping`, `tools/list`, `tools/call`. Single JSON object per POST (no batches).
  `GET/DELETE /mcp` → 405 (no SSE stream; nothing server-initiated).
- **Auth**: same bearer secret as the rest of the gateway; additionally accepts
  `?key=<secret>` (same posture as `/viewer?key=`) for connector UIs that can't
  set headers. 401 otherwise.
- **Tool surface (curated, 9 tools)** — names/descriptions/schemas lifted from
  the shim so behavior matches what SKILL.md already teaches:
  - Direct REST mapping (same endpoints the shim's proxy mode uses):
    `memory_save`→`POST /agentmemory/remember` (also increments the cataloger's
    write counter), `memory_recall`→`POST /agentmemory/search`,
    `memory_smart_search`→`POST /agentmemory/smart-search`,
    `memory_sessions`→`GET /agentmemory/sessions`, `memory_export`→`GET
    /agentmemory/export`, `memory_audit`→`GET /agentmemory/audit`,
    `memory_governance_delete`→`DELETE /agentmemory/governance/memories`.
  - Via the engine's generic `POST /agentmemory/mcp/call`:
    `memory_consolidate`, `memory_snapshot_create`.
  - Anything else upstream offers stays unexposed (deliberate: leases, mesh,
    sentinels etc. shouldn't be casually invoked against a shared brain).
- **Errors**: engine failures and argument-validation failures return MCP
  tool-level errors (`result.isError: true` + message text) so the model sees
  them; JSON-RPC errors only for protocol problems (parse −32700, batch −32600,
  unknown method −32601, unknown tool −32602).
- **Results**: engine JSON wrapped as `{"content":[{"type":"text","text":<json>}]}`
  (matching the shim); `/agentmemory/mcp/call` responses already MCP-shaped pass
  through unchanged.

### Part 2 — team-brain plugin

Plugin at `client/plugin/` (the repo doubles as its marketplace via
`.claude-plugin/marketplace.json` at the repo root, source `./client/plugin`).
The skill moves: `client/skills/team-brain/` → `client/plugin/skills/team-brain/`
(single source of truth; `overlay_instructions.sh` repointed so the fleet bundle
is unchanged in behavior).

- **`plugin.json`**: `defaultEnabled: false` (docs-endorsed for external-service
  plugins — a bare user-scope install stays inert until an explicit enable; `-s
  project` installs are unaffected since they write their own
  `enabledPlugins: true`). `userConfig`: `brain_url` (required), `brain_secret`
  (required, sensitive → keychain/credentials), `user_email` (optional).
- **`.mcp.json`**: one HTTP server `agentmemory` →
  `${user_config.brain_url}/mcp` with `Authorization: Bearer
  ${user_config.brain_secret}`. Tool names become
  `mcp__plugin_team-brain_agentmemory__memory_*` (verified format) — SKILL.md is
  kept prefix-agnostic (bare tool names) so the same file serves the fleet
  bundle (`mcp__agentmemory__*`).
- **`hooks/hooks.json`**: the same 4 hooks as the fleet overlay, commands
  `python3 "${CLAUDE_PLUGIN_ROOT}/skills/team-brain/brain.py" hook-*`.
- **`brain.py` changes** (one file serves plugin + fleet + bare-env installs):
  1. Config chain gains `CLAUDE_PLUGIN_OPTION_BRAIN_URL/_BRAIN_SECRET` (exported
     to plugin subprocesses automatically; per-project `pluginConfigs` overrides
     flow through them).
  2. `identity()` gains `CLAUDE_PLUGIN_OPTION_USER_EMAIL`.
  3. **Unconfigured = quiet**: hook subcommands exit 0 silently instead of
     erroring every turn; the SessionStart hook is the one surface — stderr
     one-liner for the human + `additionalContext` for the model ("installed
     but not configured; memory inactive").
  4. **Active-brain visibility** (compliance): when configured, SessionStart
     injects "connected to `<BRAIN_URL>` as `<user>`" context, so capture into
     the wrong client's brain is noticeable.
  5. `BRAIN_NO_DISTILL=1` env knob: recall stays, passive capture off (plugins
     have no per-hook disable; this is the voluntary-adopter escape hatch).
  6. Hardcoded `~/.claude/skills/...` paths in the status banner become
     `SELF`-relative; banner wording updated (with HTTP MCP, failed saves error
     visibly — the "silently went local" warning now applies only to the fleet
     shim path).
- **`commands/setup.md`** (`/team-brain:setup`): connectivity check + guided
  config, including writing per-project `.claude/settings.local.json`
  `pluginConfigs` for the multi-brain case.

### Install recipes (the README's "Connect your own Claude Code" section)

1. **Whole machine is one team's** (explicit opt-in): user-scope install with
   `--config brain_url=… --config brain_secret=…` + explicit `claude plugin
   enable`. Stated loudly: hooks then distill *every* project's sessions to
   that brain.
2. **Recommended default — attach to specific projects**: from the project dir,
   `claude plugin install team-brain@podbrain -s project --config …`.
   Verified contained: inert outside that project. (Config/secret are still
   global stores — fine for one brain per machine.)
3. **Different brains per project**: `-s project` install **without**
   `--config`; per project, hand-write `pluginConfigs` (both values) into
   `.claude/settings.local.json`. Never supply the secret via `--config`/the
   prompt in this mode — a global `pluginSecrets` entry overrides every
   project's settings-level secret.
4. **Other Claude surfaces** (claude.ai / Desktop / Cowork): add the brain as a
   remote connector pointing at `https://<brain>…/mcp` (no plugin, no hooks —
   interactive memory only).

## Key verified facts these designs rest on

(All empirically tested on Claude Code 2.1.170 or confirmed in current docs —
full log with dates in `tmp/CLIENT_INSTALL_OPTIONS.txt`.)

- The engine has **no MCP transport** of its own; the stdio shim proxies 7 tools
  to 6 REST endpoints + a generic `/agentmemory/mcp/call` catch-all.
- Plugin `userConfig` values substitute into plugin `.mcp.json`/hook commands and
  export as `CLAUDE_PLUGIN_OPTION_<KEY>`; sensitive values live in
  `~/.claude/.credentials.json` `pluginSecrets` (works headless on Linux).
- `required: true` is a **soft** gate: headless install succeeds enabled with
  config unset, and the MCP server is *silently omitted* — hence the SessionStart
  preflight is the real gate.
- `--config` writes to **global** stores regardless of `-s`; `-s` scopes only
  enablement. Per-project config = hand-written `pluginConfigs` (project
  `settings.local.json` > project `settings.json` > user; per-option merge).
- `${VAR:-default}` in plugin MCP config is parsed but **not applied** — never
  rely on it.
- Unset `${user_config.*}`/`${VAR}` degrades per-server, silently; skill+hooks
  unaffected.
- Disable (any scope) is a full kill-switch: hooks, skill, MCP all off.
- Plugin MCP tool names: `mcp__plugin_<plugin>_<server>__<tool>`; marketplace
  name not included.

## Open questions (resolve during build, none blocking)

- Is `.claude/settings.local.json` auto-gitignored? (Recipe 3 docs depend on the
  answer.)
- Cold-wake latency of a suspended brain vs the client's MCP connect
  timeout/backoff (test in Plan 1's live verification; document `MCP_TIMEOUT` if
  flaky).
- What Claude Desktop/Cowork load from a plugin (Ben expects skills there);
  worst case those surfaces are connector-only — acceptable v1.
- Does changing `userConfig` mid-session reconnect the plugin MCP server, or
  does it need a restart?
- Minimum Claude Code version for `userConfig` (we're on 2.1.170; consider
  `requiredMinimumVersion` in plugin.json if older clients misbehave).
