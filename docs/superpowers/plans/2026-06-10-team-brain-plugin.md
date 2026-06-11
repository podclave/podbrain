# team-brain Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package the podbrain client (skill + 4 hooks + MCP server) as a Claude Code plugin installable from this repo, with enable-time configuration (`userConfig`), quiet degradation when unconfigured, and per-project multi-brain support.

**Architecture:** Plugin lives at `client/plugin/` (skill moves into it — single source of truth; the Podclave fleet overlays repoint to the new path and are otherwise unchanged). The repo root carries `.claude-plugin/marketplace.json` so `claude plugin marketplace add podclave/podbrain` (or a local path) just works. `brain.py` gains the `CLAUDE_PLUGIN_OPTION_*` config/identity chain and a SessionStart preflight that is the real activation gate.

**Tech Stack:** Claude Code plugin system (≥2.1.170 verified), python3 stdlib (`brain.py`), bash (`overlay_instructions.sh`).

**Spec:** `docs/superpowers/specs/2026-06-10-byo-client.md`
**Depends on:** the gateway `/mcp` endpoint plan being deployed (the plugin's `.mcp.json` points at it). Tasks 1–7 can be built without it; Task 8 (dogfood) requires it live.

**Verification style note:** `brain.py` is a stdlib single-file script with no pytest harness; its tests here are exact CLI invocations with expected output, run before (must fail) and after (must pass) each change. `HOME=/tmp/fakehome` isolates from this box's real `~/.env.podclave.brain`.

---

## File structure

- Move: `client/skills/team-brain/{SKILL.md,brain.py}` → `client/plugin/skills/team-brain/`
- Create: `client/plugin/.claude-plugin/plugin.json` — manifest + userConfig (the activation prompt)
- Create: `client/plugin/hooks/hooks.json` — the 4 hooks, `${CLAUDE_PLUGIN_ROOT}`-relative
- Create: `client/plugin/.mcp.json` — the `agentmemory` HTTP server → `${user_config.brain_url}/mcp`
- Create: `client/plugin/commands/setup.md` — `/team-brain:setup`
- Create: `.claude-plugin/marketplace.json` (repo root) — repo doubles as the marketplace
- Modify: `client/plugin/skills/team-brain/brain.py` — config/identity chain, quiet-unconfigured, preflight, `BRAIN_NO_DISTILL`
- Modify: `client/plugin/skills/team-brain/SKILL.md` — path-agnostic wording, status-banner note
- Modify: `client/overlay_instructions.sh` — two source paths
- Modify: `README.md` — "Connect your own Claude Code" section (the recipes)

---

### Task 1: Plugin skeleton + marketplace (skill moves in)

**Files:**
- Move: `client/skills/` → `client/plugin/skills/`
- Create: `client/plugin/.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`
- Modify: `client/overlay_instructions.sh:17-18`

- [ ] **Step 1: Move the skill and repoint the fleet overlay script**

```bash
cd /home/sprite/podbrain
mkdir -p client/plugin
git mv client/skills client/plugin/skills
```

In `client/overlay_instructions.sh`, change the two skill rows of the `overlays=(` array from:

```bash
  "user|.claude/skills/team-brain/SKILL.md|skills/team-brain/SKILL.md|"
  "user|.claude/skills/team-brain/brain.py|skills/team-brain/brain.py|"
```

to:

```bash
  "user|.claude/skills/team-brain/SKILL.md|plugin/skills/team-brain/SKILL.md|"
  "user|.claude/skills/team-brain/brain.py|plugin/skills/team-brain/brain.py|"
```

(Overlay *destinations* are unchanged — the fleet bundle behaves identically.)

- [ ] **Step 2: Verify the overlay script still renders all 5 overlays**

```bash
bash client/overlay_instructions.sh | grep -c '^===== \['
```

Expected: `5`

- [ ] **Step 3: Write the plugin manifest**

Create `client/plugin/.claude-plugin/plugin.json`:

```json
{
  "name": "team-brain",
  "version": "0.1.0",
  "description": "Shared team memory for Claude Code — auto-recall every turn, passive capture of durable learnings, and document ingest, against a self-hosted podbrain server.",
  "author": { "name": "Podclave" },
  "homepage": "https://github.com/podclave/podbrain",
  "license": "MIT",
  "defaultEnabled": false,
  "userConfig": {
    "brain_url": {
      "type": "string",
      "title": "Brain URL",
      "description": "Your team's brain, e.g. https://my-brain.sprites.app (no trailing slash)",
      "required": true
    },
    "brain_secret": {
      "type": "string",
      "title": "Brain secret",
      "description": "The team bearer secret (ask your brain admin; on the brain box it's ~/.agentmemory/team_secret.txt)",
      "sensitive": true,
      "required": true
    },
    "user_email": {
      "type": "string",
      "title": "Your email (attribution)",
      "description": "Stamped on memories you save (—[saved by …]). Optional — falls back to git config user.email."
    }
  }
}
```

`defaultEnabled: false` is deliberate (docs-endorsed for external-service plugins): a bare user-scope install stays inert until an explicit `claude plugin enable`; `-s project` installs are unaffected because they write their own `enabledPlugins: true`.

- [ ] **Step 4: Write the marketplace manifest**

Create `.claude-plugin/marketplace.json` (repo root):

```json
{
  "name": "podbrain",
  "owner": { "name": "Podclave" },
  "plugins": [
    {
      "name": "team-brain",
      "source": "./client/plugin",
      "description": "Connect this machine's Claude Code to a shared podbrain team memory (auto-recall, passive capture, document ingest)."
    }
  ]
}
```

- [ ] **Step 5: Validate**

```bash
cd /home/sprite/podbrain && claude plugin validate client/plugin
```

Expected: validation passes (warnings acceptable, errors not). If `validate` flags the not-yet-created hooks/.mcp.json references, ignore — they're added in Task 2; re-run there.

- [ ] **Step 6: Commit**

```bash
cd /home/sprite/podbrain && git add -A client .claude-plugin
git commit -m "plugin: skeleton + marketplace; skill moves under client/plugin (fleet overlays repointed)"
```

---

### Task 2: Hooks + MCP server config

**Files:**
- Create: `client/plugin/hooks/hooks.json`
- Create: `client/plugin/.mcp.json`

- [ ] **Step 1: Write hooks.json**

Create `client/plugin/hooks/hooks.json` (same 4 hooks as the fleet overlay `client/managed-settings.d/20-team-brain.json`, paths now plugin-relative):

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "python3 \"${CLAUDE_PLUGIN_ROOT}/skills/team-brain/brain.py\" hook-recall" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "python3 \"${CLAUDE_PLUGIN_ROOT}/skills/team-brain/brain.py\" hook-stop", "async": true } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "python3 \"${CLAUDE_PLUGIN_ROOT}/skills/team-brain/brain.py\" hook-sessionend" } ] }
    ],
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "python3 \"${CLAUDE_PLUGIN_ROOT}/skills/team-brain/brain.py\" hook-sessionstart" } ] }
    ]
  }
}
```

- [ ] **Step 2: Write .mcp.json**

Create `client/plugin/.mcp.json`:

```json
{
  "mcpServers": {
    "agentmemory": {
      "type": "http",
      "url": "${user_config.brain_url}/mcp",
      "headers": {
        "Authorization": "Bearer ${user_config.brain_secret}"
      }
    }
  }
}
```

Server key is `agentmemory` → tools are `mcp__plugin_team-brain_agentmemory__memory_*` (verified naming format). Do NOT use `${VAR:-default}` anywhere — verified parsed-but-ignored on 2.1.170.

- [ ] **Step 3: Validate the complete plugin**

```bash
cd /home/sprite/podbrain && claude plugin validate client/plugin
```

Expected: passes with hooks + mcpServers listed in its inventory output.

- [ ] **Step 4: Commit**

```bash
cd /home/sprite/podbrain && git add client/plugin/hooks/hooks.json client/plugin/.mcp.json
git commit -m "plugin: hooks + HTTP MCP server (gateway /mcp via user_config)"
```

---

### Task 3: brain.py — plugin config + identity chain

**Files:**
- Modify: `client/plugin/skills/team-brain/brain.py:59-71` (`load_config`), `:74-86` (`identity`)

- [ ] **Step 1: Run the failing checks**

```bash
cd /home/sprite/podbrain/client/plugin/skills/team-brain
mkdir -p /tmp/fakehome
env -u BRAIN_URL -u BRAIN_SECRET HOME=/tmp/fakehome \
  CLAUDE_PLUGIN_OPTION_BRAIN_URL=http://localhost:8080 \
  CLAUDE_PLUGIN_OPTION_BRAIN_SECRET=$(cat ~/.agentmemory/team_secret.txt) \
  python3 brain.py health
```

Expected NOW: exits 1 with `set BRAIN_URL and BRAIN_SECRET …` (plugin options not yet honored).

```bash
env HOME=/tmp/fakehome CLAUDE_PLUGIN_OPTION_USER_EMAIL=kit@example.com BRAIN_USER= \
  python3 -c "import sys; sys.path.insert(0, '.'); import brain; print(brain.identity())"
```

Expected NOW: prints your git email or `$USER` (not `kit@example.com`).

- [ ] **Step 2: Implement**

Replace `load_config` (currently `brain.py:59-71`) with:

```python
def load_config(required=True):
    # Plugin installs export userConfig as CLAUDE_PLUGIN_OPTION_* (per-project
    # pluginConfigs overrides flow through these too); map them in first so one
    # chain serves plugin, fleet-overlay, and bare-env installs. Explicit
    # BRAIN_URL/BRAIN_SECRET env still wins.
    for src, dst in (("CLAUDE_PLUGIN_OPTION_BRAIN_URL", "BRAIN_URL"),
                     ("CLAUDE_PLUGIN_OPTION_BRAIN_SECRET", "BRAIN_SECRET")):
        if os.environ.get(src) and not os.environ.get(dst):
            os.environ[dst] = os.environ[src]
    if not (os.environ.get("BRAIN_URL") and os.environ.get("BRAIN_SECRET")):
        for f in (os.path.join(HOME, ".env.podclave.brain"),
                  os.path.join(os.path.dirname(SELF), "brain.env")):
            if os.path.isfile(f):
                for line in open(f):
                    m = re.match(r'\s*(?:export\s+)?([A-Za-z_]+)=(.*)', line)
                    if m:
                        os.environ.setdefault(m.group(1), m.group(2).strip().strip('"').strip("'"))
    url, sec = os.environ.get("BRAIN_URL"), os.environ.get("BRAIN_SECRET")
    if (not url or not sec) and required:
        sys.exit("set BRAIN_URL and BRAIN_SECRET (env, plugin config, or ~/.env.podclave.brain)")
    return url, sec
```

In `identity()` (currently `brain.py:74-86`), change the first line of the function body from:

```python
    u = os.environ.get("BRAIN_USER")
```

to:

```python
    # Explicit env beats plugin config beats platform identity beats git/$USER.
    u = os.environ.get("BRAIN_USER") or os.environ.get("CLAUDE_PLUGIN_OPTION_USER_EMAIL")
```

- [ ] **Step 3: Re-run the checks from Step 1**

Expected: the `health` check prints engine health JSON (e.g. `{"status": "healthy"…}` — requires the engine up on this box); the identity check prints `kit@example.com`. (Note `BRAIN_USER=` set-but-empty is falsy for `os.environ.get(...) or …` — that's the desired fallthrough.)

- [ ] **Step 4: Regression check — fleet env-file path still works**

```bash
env -u BRAIN_URL -u BRAIN_SECRET python3 brain.py health
```

Expected: still healthy (this box's real `~/.env.podclave.brain` supplies config — `required=True` default keeps CLI verbs strict).

- [ ] **Step 5: Commit**

```bash
cd /home/sprite/podbrain && git add client/plugin/skills/team-brain/brain.py
git commit -m "brain.py: CLAUDE_PLUGIN_OPTION_* config + identity chain"
```

---

### Task 4: brain.py — quiet-unconfigured hooks, SessionStart preflight, BRAIN_NO_DISTILL

**Files:**
- Modify: `client/plugin/skills/team-brain/brain.py` — `main()` (currently `:422-427`), `hook-sessionstart` branch (currently `:494-497`), `hook-stop`/`hook-sessionend` branches, the `<team-brain-status>` banner text (currently `:459-467`)

- [ ] **Step 1: Run the failing checks**

```bash
cd /home/sprite/podbrain/client/plugin/skills/team-brain
env -u BRAIN_URL -u BRAIN_SECRET HOME=/tmp/fakehome python3 brain.py hook-recall </dev/null; echo "exit=$?"
env -u BRAIN_URL -u BRAIN_SECRET HOME=/tmp/fakehome python3 brain.py hook-sessionstart </dev/null
```

Expected NOW: both exit 1 printing `set BRAIN_URL and BRAIN_SECRET …` — per-turn noise on an unconfigured install; this is the bug.

- [ ] **Step 2: Implement the gate in `main()`**

Replace the top of `main()` (the five lines currently at `brain.py:422-427`):

```python
def main():
    global BRAIN_URL, BRAIN_SECRET, USER_ID
    cmd = sys.argv[1] if len(sys.argv) > 1 else "help"
    a = sys.argv[2:]
    BRAIN_URL, BRAIN_SECRET = load_config()
    USER_ID = identity()
```

with:

```python
def main():
    global BRAIN_URL, BRAIN_SECRET, USER_ID
    cmd = sys.argv[1] if len(sys.argv) > 1 else "help"
    a = sys.argv[2:]
    # Hooks must never noise up or block a turn on an unconfigured install
    # (plugin installed, userConfig not yet set): they exit 0 quietly, except
    # SessionStart, which surfaces it ONCE — stderr for the human, additional-
    # Context for the model. CLI verbs stay strict (clear error + exit 1).
    hook_cmd = cmd.startswith("hook-") or cmd.startswith("_bg")
    BRAIN_URL, BRAIN_SECRET = load_config(required=not hook_cmd)
    USER_ID = identity()
    if hook_cmd and not (BRAIN_URL and BRAIN_SECRET):
        if cmd == "hook-sessionstart" and not guard():
            print("[team-brain] installed but not configured — memory features "
                  "inactive (run /team-brain:setup)", file=sys.stderr)
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext":
                    "The team-brain plugin is installed but NOT configured "
                    "(brain_url/brain_secret unset), so shared-memory recall/"
                    "capture is inactive this session. If the user asks about "
                    "memory, tell them and point them at /team-brain:setup."}}))
        return
```

- [ ] **Step 3: Implement the configured-side preflight (active-brain visibility)**

Replace the `hook-sessionstart` branch (currently `brain.py:494-497`):

```python
    elif cmd == "hook-sessionstart":
        if guard():
            return
        detach("_bgsweep", stdin_json().get("session_id") or "none")
```

with:

```python
    elif cmd == "hook-sessionstart":
        if guard():
            return
        # Name the attached brain (compliance: multi-brain machines must be able
        # to SEE which brain this project captures to — wrong-brain attachment
        # should be noticeable, not silent).
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext":
                "team-brain: this project is connected to %s (memories saved/"
                "captured there are attributed to %s)." % (BRAIN_URL, USER_ID)}}))
        if not os.environ.get("BRAIN_NO_DISTILL"):
            detach("_bgsweep", stdin_json().get("session_id") or "none")
```

- [ ] **Step 4: Add the BRAIN_NO_DISTILL knob to the two capture hooks**

In the `hook-stop` branch, change `if guard():` to `if guard() or os.environ.get("BRAIN_NO_DISTILL"):`. Same one-line change in the `hook-sessionend` branch. (Recall stays on — the knob is "recall without capture", the per-hook-disable plugins don't offer.)

- [ ] **Step 5: Make the banner path SELF-relative and fix its claim for HTTP-MCP clients**

In the `hook-recall` branch, replace the `out.append(` warning block (currently `brain.py:460-467`) with:

```python
            out.append(
                "<team-brain-status>\n⚠ TEAM BRAIN UNAVAILABLE — %s. While this lasts, "
                "auto-recall is empty AND new memories are NOT reaching the shared "
                "brain (memory tool calls will error; on fleet installs using the "
                "stdio shim they may even falsely report success). Do not treat "
                "anything \"saved\" this session as persisted; tell the user "
                "plainly. Details: `python3 %s health`.\n</team-brain-status>"
                % (warn, SELF))
```

- [ ] **Step 6: Run the checks**

```bash
cd /home/sprite/podbrain/client/plugin/skills/team-brain
# (a) unconfigured hooks: silent, exit 0
env -u BRAIN_URL -u BRAIN_SECRET HOME=/tmp/fakehome python3 brain.py hook-recall </dev/null; echo "exit=$?"
# (b) unconfigured SessionStart: stderr notice + additionalContext JSON, exit 0
env -u BRAIN_URL -u BRAIN_SECRET HOME=/tmp/fakehome python3 brain.py hook-sessionstart </dev/null; echo "exit=$?"
# (c) configured SessionStart: names the brain
env -u BRAIN_URL -u BRAIN_SECRET HOME=/tmp/fakehome \
  CLAUDE_PLUGIN_OPTION_BRAIN_URL=http://localhost:8080 \
  CLAUDE_PLUGIN_OPTION_BRAIN_SECRET=s3 BRAIN_NO_DISTILL=1 \
  python3 brain.py hook-sessionstart </dev/null
# (d) NO_DISTILL suppresses capture scheduling
rm -rf /tmp/fakehome/.claude; echo '{}' >/tmp/fakehome/t.jsonl
env HOME=/tmp/fakehome CLAUDE_PLUGIN_OPTION_BRAIN_URL=u CLAUDE_PLUGIN_OPTION_BRAIN_SECRET=s \
  BRAIN_NO_DISTILL=1 python3 brain.py hook-stop \
  <<<'{"session_id":"t","transcript_path":"/tmp/fakehome/t.jsonl"}'
ls /tmp/fakehome/.claude/.brain/ 2>/dev/null | grep -c ping; echo "(want 0)"
```

Expected: (a) no output, `exit=0`; (b) one stderr line + one JSON line containing `"additionalContext"`, `exit=0`; (c) JSON containing `connected to http://localhost:8080`; (d) `0`.

- [ ] **Step 7: Regression — CLI verbs still strict, configured hooks still work**

```bash
env -u BRAIN_URL -u BRAIN_SECRET HOME=/tmp/fakehome python3 brain.py health; echo "exit=$? (want 1)"
echo '{"prompt":"what database do we use for the team projects?"}' | python3 brain.py hook-recall | head -3
```

Expected: first exits 1 with the config error; second prints a `<team-brain-context>` block (live brain on this box).

- [ ] **Step 8: Commit**

```bash
cd /home/sprite/podbrain && git add client/plugin/skills/team-brain/brain.py
git commit -m "brain.py: quiet-unconfigured hooks, SessionStart preflight names the brain, BRAIN_NO_DISTILL"
```

---

### Task 5: SKILL.md — path-agnostic + status-note update

**Files:**
- Modify: `client/plugin/skills/team-brain/SKILL.md:18-19` (the two hardcoded paths) and `:28` (the status note)

- [ ] **Step 1: Replace the two hardcoded-path bullets**

Replace the `"file this"` bullet (line 18) and the viewer bullet (line 19) — keeping their meaning, dropping `~/.claude/skills/team-brain/`:

```markdown
- **"file this" / a document to absorb (PRD, deck, PDF, docx, md)** → run `python3 <this skill's base directory>/brain.py file "<path>" "<optional note>"` (the base directory is announced when this skill loads). This is the ONE thing not in the MCP: it uploads the document to the brain's ingest endpoint, which extracts + chunks + stores it so its contents become searchable via the MCP.
- **"open the memory viewer" / "show me the dashboard" / "browse the brain in a browser"** → run `python3 <this skill's base directory>/brain.py viewer`. Prints a ready-to-open URL (`<brain>/viewer?key=…`) that logs the browser in via a cookie; give the user the URL to click. The key is embedded by design (admin/ops-grade access to the shared dashboard).
```

- [ ] **Step 2: Replace the `<team-brain-status>` note (line 28)**

```markdown
- If a `<team-brain-status>` warning appears, the brain is **unreachable**: recall is empty and memory saves are **not persisting** (tool calls will error; on fleet installs using the stdio shim they may even falsely report success). Tell the user plainly so they don't assume their memories persisted (you needn't repeat it every message once they know).
```

- [ ] **Step 3: Verify no hardcoded skill paths remain**

```bash
grep -n '~/.claude/skills' /home/sprite/podbrain/client/plugin/skills/team-brain/SKILL.md; echo "exit=$? (want 1)"
```

- [ ] **Step 4: Commit**

```bash
cd /home/sprite/podbrain && git add client/plugin/skills/team-brain/SKILL.md
git commit -m "SKILL.md: path-agnostic (plugin + fleet), honest status-banner note"
```

---

### Task 6: /team-brain:setup command

**Files:**
- Create: `client/plugin/commands/setup.md`

- [ ] **Step 1: Write the command**

Create `client/plugin/commands/setup.md`:

```markdown
---
description: Verify the team-brain connection, or configure it (including per-project multi-brain setups)
allowed-tools: Bash, Read, Write, Edit
---

# team-brain setup

Help the user get this plugin connected to their team brain. The plugin's skill
is `team-brain`; its `brain.py` lives in that skill's base directory (announced
when the skill loads). Work through these in order:

1. **Check current state.** Run `python3 <skill base dir>/brain.py health`.
   - Healthy JSON → report "connected" plus the brain URL from the SessionStart
     context, and stop unless the user wants multi-brain setup (step 4).
   - A `set BRAIN_URL and BRAIN_SECRET` error → the plugin is unconfigured; go to 2.
   - Any other error → diagnose with the user (URL typo? secret rotated? brain down?).
2. **Single-brain configure (the normal case).** Tell the user to run:
   `claude plugin install team-brain@podbrain --config brain_url=<URL> --config brain_secret=<SECRET>`
   (works on an already-installed plugin; values also settable interactively via
   `/plugin` → team-brain → configure). Then restart the session and re-run step 1.
3. **Heads-up on scope.** If the plugin is enabled at USER scope, hooks capture
   in EVERY project on this machine. If that's not what the user wants, suggest
   project-scope enablement: `claude plugin install team-brain@podbrain -s project`
   from each project that should be connected.
4. **Multi-brain (different brains per project).** Do NOT use `--config` for
   secrets in this mode (global keychain entries override per-project settings).
   If a secret was previously set via step 2, delete the team-brain@podbrain
   entry from `pluginSecrets` in `~/.claude/.credentials.json` first — that
   leftover global secret silently overrides every per-project one.
   Instead, in each project write `.claude/settings.local.json`:

   ```json
   { "pluginConfigs": { "team-brain@podbrain": { "options": {
       "brain_url": "https://that-projects-brain.sprites.app",
       "brain_secret": "<that brain's secret>" } } } }
   ```

   Merge carefully if the file exists. Confirm the file is git-ignored (add it to
   .gitignore if not). Then restart the session and verify with step 1 — and check
   the SessionStart context names the RIGHT brain.
5. Optional: `BRAIN_NO_DISTILL=1` in the environment keeps auto-recall but turns
   off passive capture, if the user wants recall-only.
```

- [ ] **Step 2: Validate**

```bash
cd /home/sprite/podbrain && claude plugin validate client/plugin
```

Expected: passes; command `setup` listed.

- [ ] **Step 3: Commit**

```bash
cd /home/sprite/podbrain && git add client/plugin/commands/setup.md
git commit -m "plugin: /team-brain:setup command"
```

---

### Task 7: README — "Connect your own Claude Code"

**Files:**
- Modify: `README.md` (new section after "## 1. Stand up the server"; renumber old sections 2→3, 3→4, 4→5, 5→6; drop the "Single-VM dogfood" blockquote at the end of the old section 2 — the plugin supersedes it)

- [ ] **Step 1: Insert the new section** (after the "## 1. Stand up the server" section ends, before the fleet-rollout section):

````markdown
## 2. Connect your own Claude Code (plugin)

Any Claude Code ≥ 2.1.154 can join — no Podclave required:

```bash
claude plugin marketplace add podclave/podbrain        # once per machine
cd <the project you want connected>
claude plugin install team-brain@podbrain -s project \
  --config brain_url=https://<brain>.sprites.app \
  --config brain_secret=<secret>
```

That's auto-recall every turn, passive capture of durable learnings (needs
`python3` + a logged-in `claude` CLI), interactive memory tools, and `/team-brain:setup`
for diagnostics. **Pick your scope deliberately — hooks capture wherever the
plugin is enabled:**

- **Per-project (recommended, shown above):** `-s project` — active only inside
  that project, inert everywhere else. Repeat per project.
- **Whole machine:** install without `-s`, then `claude plugin enable
  team-brain@podbrain`. Every project on the machine now captures to this brain —
  only do this on a machine that's all one team's work.
- **Different brains per project** (e.g. per-client brains under separate MSAs):
  install `-s project` **without** `--config`, then put both values in each
  project's `.claude/settings.local.json` (and never set the secret via
  `--config`/the prompt — a global secret overrides every project's):

  ```json
  { "pluginConfigs": { "team-brain@podbrain": { "options": {
      "brain_url": "https://foo-brain.sprites.app",
      "brain_secret": "<foo secret>" } } } }
  ```

Each session announces which brain it's connected to; if the plugin is installed
but unconfigured it says so once and stays quiet (recall/capture inactive).
Recall-only mode: set `BRAIN_NO_DISTILL=1`.

### Other Claude surfaces (claude.ai, Desktop, Cowork)

The brain speaks MCP over HTTP directly — add it as a remote/custom connector
pointing at `https://<brain>.sprites.app/mcp` (bearer: the team secret). That
gives interactive recall/save/curation anywhere Claude runs; the automatic
hooks remain a Claude Code thing.
````

- [ ] **Step 2: Renumber the following sections and fix the architecture diagram label**

Old `## 2. Roll out to the team (client overlay bundle)` → `## 3. Roll out a Podclave fleet (client overlay bundle)`; old 3/4/5 → 4/5/6. Delete the `> **Single-VM dogfood without Podclave:** …` blockquote. In the architecture diagram (line ~26), add `/mcp` to the gateway box: change the line `│   /maintenance/run + /status (cataloger)│` to sit below a new line `│   /mcp  (MCP over HTTP — BYO clients)   │`.

- [ ] **Step 3: Check internal references**

```bash
grep -n "Single-VM dogfood\|section 2\|## [0-9]" /home/sprite/podbrain/README.md
```

Expected: numbered sections 1–6 in order, no dogfood blockquote, no stale cross-references.

- [ ] **Step 4: Commit**

```bash
cd /home/sprite/podbrain && git add README.md
git commit -m "README: Connect your own Claude Code (plugin recipes + connector surface)"
```

---

### Task 8: Dogfood end-to-end on this box (requires gateway /mcp deployed)

**Files:** none (operational)

Pre-flight notes: this box already has the fleet-style skill at `~/.claude/skills/team-brain/` — during the test the skill will appear twice (user copy + plugin copy); that's expected and harmless. There is no `/etc/claude-code/managed-mcp.json` here, so the plugin MCP will load.

- [ ] **Step 1: Add the repo as a local marketplace and install into a scratch project**

```bash
mkdir -p /tmp/plugin-dogfood && cd /tmp/plugin-dogfood && git init -q
claude plugin marketplace add /home/sprite/podbrain
claude plugin install team-brain@podbrain -s project \
  --config brain_url=http://localhost:8080 \
  --config brain_secret=$(cat ~/.agentmemory/team_secret.txt)
```

Expected: installed (scope: project), config stored.

- [ ] **Step 2: Verify MCP connection + tool naming**

```bash
cd /tmp/plugin-dogfood && claude mcp list
```

Expected: `plugin:team-brain:agentmemory: http://localhost:8080/mcp (HTTP) - ✔ Connected`.

- [ ] **Step 3: Verify hooks + preflight + recall in a real session**

```bash
cd /tmp/plugin-dogfood && claude -p --model haiku \
  "Two questions: (1) quote any session-start context you received about team-brain verbatim; (2) use the agentmemory memory_smart_search tool to search for 'postgres' and report the top result and the FULL tool name you invoked."
```

Expected: (1) quotes "team-brain: this project is connected to http://localhost:8080 …"; (2) a real result via a tool named `mcp__plugin_team-brain_agentmemory__memory_smart_search`.

- [ ] **Step 4: Verify containment**

```bash
cd /tmp && claude mcp list | grep -c team-brain; echo "(want 0 — inert outside the project)"
```

- [ ] **Step 5: Verify the unconfigured experience**

```bash
mkdir -p /tmp/plugin-dogfood2 && cd /tmp/plugin-dogfood2 && git init -q
claude plugin install team-brain@podbrain -s project   # no --config… but NOTE: config
# stores are GLOBAL, so step 1's values still apply. To see the unconfigured path,
# temporarily remove them:
python3 - <<'EOF'
import json, pathlib
p = pathlib.Path.home() / ".claude/settings.json"
d = json.loads(p.read_text())
stash = d.get("pluginConfigs", {}).pop("team-brain@podbrain", None)
p.write_text(json.dumps(d, indent=2))
(pathlib.Path("/tmp/plugin-dogfood2/stash.json")).write_text(json.dumps(stash))
EOF
# also stash the secret:
python3 - <<'EOF'
import json, pathlib
p = pathlib.Path.home() / ".claude/.credentials.json"
d = json.loads(p.read_text())
stash = d.get("pluginSecrets", {}).pop("team-brain@podbrain", None)
p.write_text(json.dumps(d))
(pathlib.Path("/tmp/plugin-dogfood2/stash-secret.json")).write_text(json.dumps(stash))
EOF
claude -p --model haiku "Quote any session-start context about team-brain verbatim." 
```

Expected: the model quotes the "installed but NOT configured … /team-brain:setup" context; the session works normally otherwise. Then **restore both stashed values**:

```bash
python3 - <<'EOF'
import json, pathlib
home = pathlib.Path.home()
cfg = json.loads((home / ".claude/settings.json").read_text())
stash = json.loads(pathlib.Path("/tmp/plugin-dogfood2/stash.json").read_text())
if stash is not None:
    cfg.setdefault("pluginConfigs", {})["team-brain@podbrain"] = stash
(home / ".claude/settings.json").write_text(json.dumps(cfg, indent=2))
cred = json.loads((home / ".claude/.credentials.json").read_text())
sec = json.loads(pathlib.Path("/tmp/plugin-dogfood2/stash-secret.json").read_text())
if sec is not None:
    cred.setdefault("pluginSecrets", {})["team-brain@podbrain"] = sec
(home / ".claude/.credentials.json").write_text(json.dumps(cred))
print("restored")
EOF
```

Re-run Step 3 to confirm restoration.

- [ ] **Step 6: Clean up**

```bash
cd /tmp/plugin-dogfood && claude plugin uninstall team-brain@podbrain
cd /tmp/plugin-dogfood2 && claude plugin uninstall team-brain@podbrain 2>/dev/null || true
claude plugin marketplace remove podbrain
rm -rf /tmp/plugin-dogfood /tmp/plugin-dogfood2 /tmp/fakehome
claude plugin list && claude mcp list   # confirm no team-brain residue
```

- [ ] **Step 7: Checkpoint + record findings**

```bash
sprite-env checkpoints create --comment "team-brain plugin dogfooded end-to-end"
```

Record in `tmp/CLIENT_INSTALL_OPTIONS.txt` open items: actual tool-name string observed, whether `claude plugin validate`/Desktop questions changed anything, any cold-wake observations.
