# Rollout guide

How to stand up a brain and roll it out to a team via the Podclave org overlay.

## 1. Stand up the server (once, on the brain Sprite)

The brain Sprite must be in **public URL mode** (the bearer secret is the gatekeeper).

```bash
git clone https://github.com/podclave/podbrain.git && cd podbrain
bash server/install-brain.sh
```

The installer prints a `BRAIN_URL` + `BRAIN_SECRET` block at the end (secret also
at `~/.agentmemory/team_secret.txt`). Two things the installer can't do itself:

- **Set public auth mode** — do this on the Sprite/Podclave side (the bearer
  secret is the gatekeeper). Without it, clients can't reach the brain.
- **Authenticate Claude on the brain box** — the LLM cataloger
  (`AGENTMEMORY_PROVIDER=agent-sdk`) runs `claude` here. If Claude isn't logged in
  on this box, capture/recall/ingest/dedup all still work, but deep consolidation
  silently degrades to no-op. Run `claude` once to log in for the full cataloger.

Verify:
```bash
curl https://<brain>.sprites.app/healthz
curl -H "Authorization: Bearer <secret>" https://<brain>.sprites.app/agentmemory/health
```

## 2. Client config bundle (the overlay set)

Add these **5 overlays** to the `team-brain` bundle. Relative paths
land in `$HOME`; `.env.podclave.*` is auto-sourced into every shell. `brain.py` is
always invoked via `python3 …/brain.py`, so no executable bit is needed.

| # | Overlay path | Owner | Contents = repo file |
|---|---|---|---|
| 1 | `.claude/skills/team-brain/SKILL.md` | user | `client/skills/team-brain/SKILL.md` |
| 2 | `.claude/skills/team-brain/brain.py` | user | `client/skills/team-brain/brain.py` |
| 3 | `.env.podclave.brain` | user | `client/env.podclave.brain.template` (fill URL + secret) |
| 4 | `/etc/claude-code/managed-settings.d/20-team-brain.json` | **root** | `client/managed-settings.d/20-team-brain.json` |
| 5 | `/etc/claude-code/managed-mcp.json` | **root** | `client/managed-mcp.json` |

**Overlay #3** is the only one with secrets, so its real contents live in Podclave
(not git). Identical for the whole org:

```sh
export BRAIN_URL="https://<brain>.sprites.app"
export BRAIN_SECRET="<secret>"
```

Identity is **not** in the bundle — `brain.py` reads `~/.podclave/user-email`
(written by Podclave on Setup), falling back to git email / `$USER`. So every
teammate's overlays are byte-identical; attribution still works per-person.

Why **#4** is safe org-wide: Claude Code **combines** hooks across all settings
sources, so this managed file adds the auto-recall + auto-capture hooks **without
touching anyone's own `~/.claude/settings.json`**. It's `owner: root` so users
can't disable it; re-provisioning overwrites just this one file (idempotent). It
also carries `permissions.allow` for the **safe** agentmemory MCP tools (read +
reversible curation), so those run without prompts; `memory_governance_delete` and
the agent-workflow tools are omitted → they prompt.

**Overlay #5 — the agentmemory MCP** (`owner: root`): this is the interactive
memory surface. It runs a local `npx @agentmemory/mcp` stdio shim in **proxy mode**
against the shared brain (`AGENTMEMORY_FORCE_PROXY=1`, `AGENTMEMORY_URL=${BRAIN_URL}`,
`AGENTMEMORY_SECRET=${BRAIN_SECRET}`, `AGENTMEMORY_TOOLS=all`); calls go to
`/agentmemory/mcp/*` through the bearer-gated gateway. Caveats, all real:
> - **`managed-mcp.json` is EXCLUSIVE** — once deployed, Claude Code loads *only*
>   the servers it defines; teammates' own local/project MCP servers stop loading.
>   Add any other team MCP to this same file. `allowAllClaudeAiMcps: true` keeps
>   users' claude.ai connectors.
> - Managed MCP servers are **auto-trusted** (no per-user approval prompt).
> - Needs **node** on the client (the shim; `npx -y` self-fetches on first use —
>   a one-time hit) and Claude Code **≥ 2.1.149** (for `allowAllClaudeAiMcps`).
> - No secret in the file: `${BRAIN_URL}`/`${BRAIN_SECRET}` expand from #3.

> Manual / single-VM dogfood (no overlay): place the same files yourself —
> copy `client/skills/team-brain/{SKILL.md,brain.py}` to `~/.claude/skills/team-brain/`,
> write `~/.env.podclave.brain` (URL + secret), copy
> `client/managed-settings.d/20-team-brain.json` and `client/managed-mcp.json` to
> `/etc/claude-code/` (the latter at `/etc/claude-code/managed-mcp.json`, root).
> Then `python3 ~/.claude/skills/team-brain/brain.py health`, and in a Claude
> session run `/mcp` to confirm the `agentmemory` server is connected.

## 3. Schedule the cataloger (Podclave per-Sprite Schedule)

Point a Schedule at the brain so consolidation runs on a cadence (and wakes the
box to do it). Configure on the **brain** Sprite:

| Field | Value |
|---|---|
| Method | `POST` |
| Path | `/maintenance/run` |
| Interval | e.g. `3600` (hourly) or `21600` (6h) — min 60s |
| Headers | `Authorization: Bearer <secret>` |

**The `Authorization` header is required** — the path goes through the gateway's
auth; without it you get 401. The scheduled POST also wakes a suspended box
(incoming HTTP auto-starts the gateway), so the full spin-down → wake → catalog →
keep-alive → re-suspend loop closes on its own. The cataloger no-ops cheaply when
there's nothing new, so a frequent interval is fine.

Check it ran: `GET /maintenance/status` (with the bearer header) →
`last_run`, `writes_since_run`, `last_result`.

## 4. Verify the loop on one VM

After overlay Setup on a teammate VM:

```bash
python3 ~/.claude/skills/team-brain/brain.py health      # gateway reachable -> {"status":"healthy"}
```

Then in a real Claude Code session on that VM:
- run `/mcp` → the `agentmemory` server shows **connected** (proxying to the brain). If it shows a local/7-tool fallback, the `livez` probe failed — check `BRAIN_URL`/`BRAIN_SECRET` reachability (`AGENTMEMORY_FORCE_PROXY=1` should skip the probe).
- ask it to "remember <fact>" then "what do we know about <topic>" → it uses `mcp__agentmemory__memory_save` / `memory_smart_search`,
- ask something about a known project area → expect a `<team-brain-context>` block injected (auto-recall hook),
- do some work / state a decision, end the turn → after ~90s the async capture distills durable learnings and pushes them (verify via `memory_smart_search`),
- "file this `<path>`" → `brain.py file` ingests it; contents become searchable via the MCP.

## 5. Secret rotation

```bash
openssl rand -hex 24 > ~/.agentmemory/team_secret.txt   # on the brain Sprite
# update AGENTMEMORY_SECRET in ~/.agentmemory/.env, then:
sprite-env services restart agentmemory && sprite-env services restart team-brain
```
Then update `brain.env` (overlay) + the Schedule's `Authorization` header and re-run Setup.
