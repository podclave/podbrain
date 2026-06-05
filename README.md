# podbrain

A central, self-hosted **team brain** for AI coding agents. Teammates point their
Claude Code at one bearer-gated URL and it both **uses** the team's shared
knowledge (auto-recall) and **adds** to it (auto-capture) — plus ingests
documents (PRDs, decks, PDFs) and catalogs everything in the background. Runs on
a single spin-down Sprite, keyless (local embeddings + the Claude subscription).

## Architecture

```
  teammates' Claude Code ──┐  skill + hooks (curl), bearer token
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
client/
  install-client.sh        per-VM onboarding (overlay runs this)
  skills/team-brain/       skill + brain.sh helper + hooks + distiller
  managed-settings.d/      hook registration (zero-merge, org-wide)
  CLAUDE.snippet.md        optional CLAUDE.md block
```

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

Each teammate's Claude Code VM (shipped via the Podclave org overlay):

```bash
BRAIN_URL=https://<brain>.sprites.app BRAIN_SECRET=<secret> bash client/install-client.sh
```

This installs the `team-brain` skill, renders `brain.env`, and drops the hooks
into `/etc/claude-code/managed-settings.d/` — which Claude Code **combines**
across all settings sources, so the user's own `settings.json` is never touched.
Per-user attribution comes from `~/.podclave/user-email` (no per-user config).

After that, the teammate's Claude:
- **auto-recalls** relevant team knowledge each turn (UserPromptSubmit hook),
- **auto-captures** durable learnings after work (async Stop hook → local
  `claude -p` distiller → push; secrets scrubbed, only distilled facts leave the VM),
- **recall / remember / file** on demand via the skill (`brain.sh`).

"File this <document>" → the file is uploaded to `/ingest`, extracted
server-side (pdf/docx/pptx/md), chunked, stored, and made searchable.

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
