# podbrain

A central, self-hosted **team brain** for AI coding agents. Teammates point their
Claude Code at one bearer-gated URL and it both **uses** the team's shared
knowledge (auto-recall) and **adds** to it (auto-capture) — plus ingests
documents (PRDs, decks, PDFs) and catalogs everything in the background. Runs on
a single spin-down Sprite, keyless (local embeddings + the Claude subscription).

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

## Repo layout

```
server/
  install-brain.sh         one-shot, idempotent server provisioner
  gateway/app.py           the FastAPI gateway
  gateway/requirements.txt pinned deps
client/                    shipped as a Podclave config bundle (5 overlays)
  README.md                    the overlay manifest (path -> contents)
  skills/team-brain/SKILL.md   skill manifest (routes memory to the MCP; file -> brain.py)
  skills/team-brain/brain.py   single-file Python (stdlib): the deterministic hooks
                               (auto-recall + passive distill) + file ingest
  env.podclave.brain.template  -> ~/.env.podclave.brain (URL + secret, auto-sourced)
  managed-settings.d/20-team-brain.json  -> /etc/... (hooks + MCP-tool perms, owner root)
  managed-mcp.json             -> /etc/claude-code/managed-mcp.json (the agentmemory MCP, owner root)
```

See [client/README.md](client/README.md) for the overlay manifest and
[docs/ROLLOUT.md](docs/ROLLOUT.md) for the full rollout.

## Stand up a new brain (server)

On a fresh Sprite, from a checkout:

```bash
bash server/install-brain.sh         # installs engine, gateway, both services
# prints the generated bearer secret + public URL
```

Verify:

```bash
curl https://<brain>.sprites.app/healthz
curl -H "Authorization: Bearer <secret>" https://<brain>.sprites.app/agentmemory/health
```

## Onboard a teammate (client)

Rollout is via a **Podclave config bundle** — 5 overlays, no installer. See
[client/README.md](client/README.md) for the exact overlay manifest (path →
contents) and [docs/ROLLOUT.md](docs/ROLLOUT.md) for the full rollout (server,
schedule, verification).

Per-user attribution comes from `~/.podclave/user-email` (no per-user config), so
every teammate's overlays are byte-identical. Claude Code **combines** hooks
across settings sources, so the `/etc` hooks file never touches anyone's own
`settings.json`.

After that, the teammate's Claude:
- **auto-recalls** relevant team knowledge each turn (UserPromptSubmit hook),
- **auto-captures** durable learnings after work (async Stop hook → local
  `claude -p` distiller → push; secrets scrubbed, only distilled facts leave the VM),
- **recalls / saves / curates** on demand via the **agentmemory MCP** (the native
  `memory_*` toolset — search, save, governance-delete, consolidate, snapshot, audit),
- **ingests documents** via `brain.py file <path>` (the one capability not in the MCP).

"File this <document>" → the file is uploaded to `/ingest`, extracted
server-side (pdf/docx/pptx/md), chunked, stored, and made searchable via the MCP.

## The cataloger

The gateway runs consolidation when the box is already awake (spin-down-native):
after `BRAIN_MAINT_WRITES` (default 20) writes and `BRAIN_MAINT_MIN_SECS`
(default 1800) elapsed, it runs `consolidate-pipeline → reflect → auto-forget`
in the background, holding a Sprite keep-alive task so the box can't suspend
mid-run. For guaranteed runs, hit `POST /maintenance/run` from an external
scheduler. `GET /maintenance/status` reports state.

## Notes

- Sprite auth mode is `public`; the **bearer secret is the gatekeeper**. Rotate by
  editing `~/.agentmemory/team_secret.txt` + `.env` and restarting both services.
- Secrets never live in this repo: the server generates its own; `brain.env` is
  rendered per-VM from env (`brain.env.template` is the placeholder form).
