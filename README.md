# podbrain

A central, self-hosted **team brain** for AI coding agents. Teammates point their
Claude Code at one bearer-gated URL and it both **uses** the team's shared
knowledge (auto-recall) and **adds** to it (auto-capture) — plus ingests
documents (PRDs, decks, PDFs) and catalogs everything in the background. Runs on
a single spin-down Sprite, keyless (local embeddings + the Claude subscription).

> **Built for [Podclave](https://podclave.com).** podbrain runs on a Podclave **Sprite**
> and rolls out to your team as a Podclave config-overlay bundle — the spin-down
> hosting, managed `/etc` overlays, per-user identity, and per-Sprite Schedules it
> relies on are Podclave features. Get a team set up at <https://podclave.com>.

## Architecture

```
  teammates' Claude Code ──┐  agentmemory MCP (interactive) + hooks (auto) + skill, bearer token
                           ▼
   https://<brain>.sprites.app   (public, one bearer secret)
                           │
        ┌──────────────────▼───────────────────┐  service: team-brain  :8080
        │  gateway (FastAPI) — the front door    │
        │   /agentmemory/*  passthrough          │
        │   /ingest/upload  /docs/{id}           │
        │   /maintenance/run + /status (cataloger)│
        │   /viewer  /healthz                    │
        └───┬───────────────┬───────────────────┘
   passthrough          proxy │
        ┌───▼─────────────┐  ┌▼──────────────┐  service: agentmemory (internal)
        │ agentmemory :3111│  │ viewer  :3113 │
        │ keyless engine   │  └───────────────┘
        └──────────────────┘
   ~/brain-docs/  originals + manifest.db (sha256-idempotent)
```

- **Engine:** [`@agentmemory/agentmemory`](https://github.com/rohitg00/agentmemory) — local embeddings (`all-MiniLM-L6-v2`), BM25+vector+graph hybrid search. Apache-2.0.
- **Gateway (ours):** auth, document ingest/retrieval, viewer proxy, and the activity-triggered cataloger. This is the productized layer.
- **Keyless:** no API keys. Embeddings run locally; the LLM cataloger uses the Claude subscription on the box (`AGENTMEMORY_PROVIDER=agent-sdk`).

## Setup at a glance

1. `git clone https://github.com/podclave/podbrain.git && cd podbrain`
2. `bash server/install-brain.sh` — stand up the brain (once)
3. `bash client/overlay_instructions.sh` — render the client overlays
4. Paste the printed blocks into your Podclave `team-brain` bundle
5. Done — every teammate's Claude Code is now wired up

Details for each step below.

## 1. Stand up the server

On a fresh Sprite in **public URL mode** (the bearer secret is the gatekeeper):

```bash
git clone https://github.com/podclave/podbrain.git && cd podbrain
bash server/install-brain.sh        # installs the engine, gateway, and both services
```

The installer is idempotent and prints a `BRAIN_URL` + `BRAIN_SECRET` block at the
end (the secret is also at `~/.agentmemory/team_secret.txt`).

**Two things the installer can't do itself:**

- **Set public auth mode** — on the Sprite/Podclave side. Without it, clients can't reach the brain.
- **Log `claude` in on the brain box** — the LLM cataloger (`AGENTMEMORY_PROVIDER=agent-sdk`) runs `claude` here. Capture/recall/ingest all work without it, but deep consolidation silently degrades to a no-op. Run `claude` once to log in.

Verify:

```bash
curl https://<brain>.sprites.app/healthz
curl -H "Authorization: Bearer <secret>" https://<brain>.sprites.app/agentmemory/health
```

## 2. Roll out to the team (client overlay bundle)

The client ships as a **Podclave config bundle** — 5 overlay files, no installer.
On the brain box, render them all:

```bash
bash client/overlay_instructions.sh
```

It prints all five overlays — each with its destination path + owner, pulled
straight from the repo — and **pre-fills** the secrets file (`.env.podclave.brain`)
with this brain's live `BRAIN_URL`/`BRAIN_SECRET`. Paste each block into the
`team-brain` bundle in Podclave at the path it shows (relative paths land in `$HOME`;
`brain.py` runs via `python3 …`, so no executable bit is needed). That's the rollout.

Key things to know:

- **Overlays are byte-identical for the whole org.** Per-user attribution comes
  from `~/.podclave/user-email` (written by Podclave on Setup; falls back to git
  email / `$USER`), so there's no per-user config.
- **The two `/etc/claude-code/` files are `owner: root`** so users can't disable them.
  `managed-settings.d/20-team-brain.json` adds the auto-recall/auto-capture hooks —
  Claude Code *combines* hooks across all settings sources, so it never touches anyone's
  own `~/.claude/settings.json` — plus `permissions.allow` for the **safe** MCP tools
  (read + reversible curation); `memory_governance_delete` and the agent-workflow tools
  are omitted, so they prompt.
- **`managed-mcp.json` is the agentmemory MCP** — a local `npx @agentmemory/mcp` stdio
  shim in **proxy mode** against the shared brain (`AGENTMEMORY_FORCE_PROXY=1`,
  `${BRAIN_URL}`/`${BRAIN_SECRET}` from the env file). Caveats, all real:
  - **`managed-mcp.json` is EXCLUSIVE** — once deployed, Claude Code loads *only*
    the servers it defines; teammates' own local/project MCP servers stop loading.
    Add any other team MCP to this same file. `allowAllClaudeAiMcps: true` keeps
    users' claude.ai connectors.
  - Managed MCP servers are **auto-trusted** (no per-user approval prompt).
  - Needs **node** on the client (the shim; `npx -y` self-fetches on first use) and
    Claude Code **≥ 2.1.149** (for `allowAllClaudeAiMcps`).

> **Single-VM dogfood without Podclave:** place the files yourself — copy
> `client/skills/team-brain/{SKILL.md,brain.py}` to `~/.claude/skills/team-brain/`,
> save the `.env.podclave.brain` block from `overlay_instructions.sh` to `~/.env.podclave.brain`, and copy
> `client/managed-settings.d/20-team-brain.json` + `client/managed-mcp.json` into
> `/etc/claude-code/` (the latter as `/etc/claude-code/managed-mcp.json`, root).

## 3. Schedule the cataloger

The gateway runs consolidation on its own when the box is already awake (after
`BRAIN_MAINT_WRITES`, default 20, writes and `BRAIN_MAINT_MIN_SECS`, default 1800,
elapsed: `consolidate-pipeline → reflect → auto-forget`, holding a Sprite keep-alive
so it can't suspend mid-run). For **guaranteed** runs, point a Podclave per-Sprite
Schedule at the brain:

| Field | Value |
|---|---|
| Method | `POST` |
| Path | `/maintenance/run` |
| Interval | e.g. `3600` (hourly) or `21600` (6h) — min 60s |
| Headers | `Authorization: Bearer <secret>` |

The `Authorization` header is **required** (the path is bearer-gated → 401 without
it). The scheduled POST also wakes a suspended box, so the full spin-down → wake →
catalog → keep-alive → re-suspend loop closes on its own; the cataloger no-ops
cheaply when there's nothing new. Check state: `GET /maintenance/status`.

## 4. Verify a teammate VM

After overlay Setup on a teammate's VM:

```bash
python3 ~/.claude/skills/team-brain/brain.py health    # gateway reachable → {"status":"healthy"}
```

Then in a real Claude Code session there:

- run `/mcp` → the `agentmemory` server shows **connected** (proxying to the brain).
  A local/7-tool fallback means the `livez` probe failed — check `BRAIN_URL`/`BRAIN_SECRET`.
- "remember `<fact>`" then "what do we know about `<topic>`" → it uses
  `memory_save` / `memory_smart_search`.
- ask about a known project area → expect a `<team-brain-context>` block (auto-recall hook).
- state a decision and end the turn → after ~90s the async capture distills durable
  learnings and pushes them (secrets scrubbed; only distilled facts leave the VM).
- "file this `<path>`" → `brain.py file` ingests it server-side (pdf/docx/pptx/md),
  and its contents become searchable via the MCP.

## 5. Rotate the secret

```bash
openssl rand -hex 24 > ~/.agentmemory/team_secret.txt          # on the brain Sprite
# update AGENTMEMORY_SECRET in ~/.agentmemory/.env, then:
sprite-env services restart agentmemory && sprite-env services restart team-brain
```

Then re-run `client/overlay_instructions.sh` to get the new #3, update that overlay
and the Schedule's `Authorization` header, and re-run Setup.

## Repo layout

```
server/
  install-brain.sh         one-shot, idempotent server provisioner
  gateway/app.py           the FastAPI gateway
  gateway/requirements.txt pinned deps
client/
  overlay_instructions.sh  prints the 5 client overlays for the Podclave bundle
  skills/team-brain/SKILL.md   skill manifest (routes memory to the MCP; file → brain.py)
  skills/team-brain/brain.py   single-file Python (stdlib): hooks + file ingest
  env.podclave.brain.template  → ~/.env.podclave.brain (URL + secret, auto-sourced)
  managed-settings.d/20-team-brain.json  → /etc/... (hooks + MCP-tool perms, root)
  managed-mcp.json             → /etc/claude-code/managed-mcp.json (the agentmemory MCP, root)
docs/
  DEVELOPING.md            working ON podbrain: design decisions, gotchas, tradeoffs
```
