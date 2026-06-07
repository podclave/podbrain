# Rollout guide

How to stand up a brain and roll it out to a team via the Podclave org overlay.

## 1. Stand up the server (once, on the brain Sprite)

The brain Sprite must be in **public URL mode** (the bearer secret is the gatekeeper).

```bash
git clone https://github.com/podclave/podbrain.git && cd podbrain
bash server/install-brain.sh
```

Note the two outputs:
- **Secret** — printed at the end (also at `~/.agentmemory/team_secret.txt`).
- **Public URL** — `sprite url` (e.g. `https://<brain>.sprites.app`).

Verify:
```bash
curl https://<brain>.sprites.app/healthz
curl -H "Authorization: Bearer <secret>" https://<brain>.sprites.app/agentmemory/health
```

## 2. Client config bundle (the overlay set)

Add these **4 overlays** to the `team-brain` bundle. Relative paths
land in `$HOME`; `.env.podclave.*` is auto-sourced into every shell. `brain.sh` is
always invoked via `bash …/brain.sh`, so no executable bit is needed.

| # | Overlay path | Owner | Contents = repo file |
|---|---|---|---|
| 1 | `.claude/skills/team-brain/SKILL.md` | user | `client/skills/team-brain/SKILL.md` |
| 2 | `.claude/skills/team-brain/brain.sh` | user | `client/skills/team-brain/brain.sh` |
| 3 | `.env.podclave.brain` | user | `client/env.podclave.brain.template` (fill URL + secret) |
| 4 | `/etc/claude-code/managed-settings.d/20-team-brain.json` | **root** | `client/managed-settings.d/20-team-brain.json` |

**Overlay #3** is the only one with secrets, so its real contents live in Podclave
(not git). Identical for the whole org:

```sh
export BRAIN_URL="https://<brain>.sprites.app"
export BRAIN_SECRET="<secret>"
```

Identity is **not** in the bundle — `brain.sh` reads `~/.podclave/user-email`
(written by Podclave on Setup), falling back to git email / `$USER`. So every
teammate's overlays are byte-identical; attribution still works per-person.

Why **#4** is safe org-wide: Claude Code **combines** hooks across all settings
sources, so this managed file adds the auto-recall + auto-capture hooks **without
touching anyone's own `~/.claude/settings.json`**. It's `owner: root` so users
can't disable it; re-provisioning overwrites just this one file (idempotent).

> Manual / single-VM dogfood alternative (no overlay):
> ```bash
> BRAIN_URL=https://<brain>.sprites.app BRAIN_SECRET=<secret> \
>   bash client/install-client.sh --with-hooks
> ```

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
bash ~/.claude/skills/team-brain/brain.sh health      # -> {"status":"healthy"}
bash ~/.claude/skills/team-brain/brain.sh remember "rollout smoke test from $(whoami)"
bash ~/.claude/skills/team-brain/brain.sh recall "rollout smoke test"
```

Then in a real Claude Code session on that VM:
- ask something about a known project area → expect a `<team-brain-context>` block injected (auto-recall hook),
- do some work / state a decision, end the turn → after ~90s the async capture distills durable learnings and pushes them (check with `recall`),
- "file this `<path>`" → ingested and searchable.

## 5. Secret rotation

```bash
openssl rand -hex 24 > ~/.agentmemory/team_secret.txt   # on the brain Sprite
# update AGENTMEMORY_SECRET in ~/.agentmemory/.env, then:
sprite-env services restart agentmemory && sprite-env services restart team-brain
```
Then update `brain.env` (overlay) + the Schedule's `Authorization` header and re-run Setup.
