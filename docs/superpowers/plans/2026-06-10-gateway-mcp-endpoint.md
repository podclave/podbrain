# Gateway MCP Endpoint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a stateless MCP-over-HTTP endpoint (`POST /mcp`) to the podbrain gateway so any Claude Code (and claude.ai/Desktop connectors) can use the team brain with no local npx shim — and no silent-local-save failure mode.

**Architecture:** New module `server/gateway/mcp_endpoint.py` exposes a FastAPI `APIRouter` speaking MCP Streamable HTTP (hand-rolled JSON-RPC — no new deps), fulfilling a curated 9-tool surface against the agentmemory engine's REST API exactly as the upstream stdio shim does in proxy mode. `app.py` mounts it with the gateway's existing secret, engine base URL, and write-counter.

**Tech Stack:** Python 3.11+, FastAPI (already pinned), httpx (already pinned), pytest for tests.

**Spec:** `docs/superpowers/specs/2026-06-10-byo-client.md`

**Reference facts** (verified against the installed shim, `@agentmemory/agentmemory/dist/standalone.mjs`):
- Proxy-mode REST mapping: `memory_save`→`POST /agentmemory/remember` `{content,type,concepts[],files[]}`; `memory_recall`→`POST /agentmemory/search` `{query,limit,format,token_budget?}`; `memory_smart_search`→`POST /agentmemory/smart-search` `{query,limit,format?,token_budget?}`; `memory_sessions`→`GET /agentmemory/sessions?limit=N`; `memory_export`→`GET /agentmemory/export`; `memory_audit`→`GET /agentmemory/audit?limit=N`; `memory_governance_delete`→`DELETE /agentmemory/governance/memories` `{memoryIds[],reason}`; everything else→`POST /agentmemory/mcp/call` `{name,arguments}` (returns MCP-shaped `{content:[…]}`).
- Shim validation: comma-string OR array → list for `concepts`/`files`/`memoryIds`; limits clamped to 1..100 with per-tool defaults (recall/smart_search 10, sessions 20, audit 50).

---

## File structure

- Create: `server/gateway/mcp_endpoint.py` — the whole endpoint: tool table, validation, engine dispatch, JSON-RPC route. One responsibility: MCP over HTTP.
- Create: `server/gateway/test_mcp_endpoint.py` — pytest suite (engine faked via monkeypatch).
- Modify: `server/gateway/app.py` — 2 lines: import + `include_router` (after `note_writes` is defined).

The module is named `mcp_endpoint` (NOT `mcp`) to avoid shadowing the `mcp` pip package if it's ever installed.

---

### Task 1: Test scaffolding + protocol layer (initialize / ping / notifications / errors / auth)

**Files:**
- Create: `server/gateway/test_mcp_endpoint.py`
- Create: `server/gateway/mcp_endpoint.py`

- [ ] **Step 1: Install pytest (test-only dep; not added to requirements.txt)**

```bash
python3 -m pip install --no-cache-dir --user pytest
```

- [ ] **Step 2: Write the failing protocol tests**

Create `server/gateway/test_mcp_endpoint.py`:

```python
"""Tests for the gateway's MCP-over-HTTP endpoint. The engine is faked by
monkeypatching mcp_endpoint.engine_call, so these run with no engine present."""
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

import mcp_endpoint

SECRET = "testsecret"
AUTH = {"Authorization": f"Bearer {SECRET}"}


@pytest.fixture()
def harness(monkeypatch):
    """TestClient wired to a router whose engine calls are recorded, not sent."""
    calls = []

    async def fake_engine(am_base, secret, method, path, payload=None):
        calls.append({"method": method, "path": path, "payload": payload})
        return {"ok": True}

    monkeypatch.setattr(mcp_endpoint, "engine_call", fake_engine)
    writes = []
    app = FastAPI()
    app.include_router(
        mcp_endpoint.build_router(SECRET, "http://am", lambda n=1: writes.append(n)))
    return TestClient(app), calls, writes


def rpc(client, method, params=None, id_=1, headers=AUTH):
    return client.post("/mcp", headers=headers, json={
        "jsonrpc": "2.0", "id": id_, "method": method, "params": params or {}})


def test_requires_auth(harness):
    client, _, _ = harness
    r = rpc(client, "ping", headers={})
    assert r.status_code == 401


def test_query_key_auth_accepted(harness):
    client, _, _ = harness
    r = client.post(f"/mcp?key={SECRET}", json={
        "jsonrpc": "2.0", "id": 1, "method": "ping", "params": {}})
    assert r.status_code == 200
    assert r.json()["result"] == {}


def test_initialize_echoes_known_protocol_version(harness):
    client, _, _ = harness
    r = rpc(client, "initialize", {"protocolVersion": "2025-03-26",
                                   "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}})
    body = r.json()
    assert body["result"]["protocolVersion"] == "2025-03-26"
    assert body["result"]["capabilities"] == {"tools": {}}
    assert body["result"]["serverInfo"]["name"] == "team-brain"


def test_initialize_unknown_version_returns_latest(harness):
    client, _, _ = harness
    r = rpc(client, "initialize", {"protocolVersion": "1999-01-01"})
    assert r.json()["result"]["protocolVersion"] == "2025-06-18"


def test_notification_returns_202(harness):
    client, _, _ = harness
    r = client.post("/mcp", headers=AUTH, json={
        "jsonrpc": "2.0", "method": "notifications/initialized"})  # no id
    assert r.status_code == 202


def test_batch_rejected(harness):
    client, _, _ = harness
    r = client.post("/mcp", headers=AUTH, json=[{"jsonrpc": "2.0", "id": 1, "method": "ping"}])
    assert r.json()["error"]["code"] == -32600


def test_unknown_method(harness):
    client, _, _ = harness
    r = rpc(client, "resources/list")
    assert r.json()["error"]["code"] == -32601


def test_get_and_delete_are_405(harness):
    client, _, _ = harness
    assert client.get("/mcp", headers=AUTH).status_code == 405
    assert client.delete("/mcp", headers=AUTH).status_code == 405
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd /home/sprite/podbrain/server/gateway && python3 -m pytest test_mcp_endpoint.py -q
```

Expected: collection error — `ModuleNotFoundError: No module named 'mcp_endpoint'`.

- [ ] **Step 4: Write the protocol layer**

Create `server/gateway/mcp_endpoint.py`:

```python
"""MCP-over-HTTP endpoint (stateless Streamable HTTP) for the team-brain gateway.

Speaks the MCP Streamable HTTP transport directly — one POST /mcp route handling
JSON-RPC — and fulfills tool calls against the agentmemory engine's REST API,
exactly as the @agentmemory/mcp stdio shim does in proxy mode.

Why this exists instead of clients running the npx shim:
  - no node prerequisite on clients;
  - the shim, on any failed proxy call, silently falls back to a throwaway local
    store AND REPORTS SUCCESS — here a down brain is a visible tool error;
  - claude.ai / Claude Desktop / Cowork can attach to the same URL as a remote
    connector (hence the ?key= auth fallback, mirroring /viewer?key=).

Stateless by design: every exposed tool is one request/response. No sessions, no
SSE stream, no server-initiated messages — so GET/DELETE return 405, which the
Streamable HTTP spec permits for servers that don't offer a stream.

Hand-rolled rather than the `mcp` pip package: the protocol subset we need is
four methods, and the gateway keeps its zero-new-deps posture.
"""
import json

import httpx
from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, Response

PROTOCOL_VERSIONS = {"2024-11-05", "2025-03-26", "2025-06-18"}
LATEST_PROTOCOL = "2025-06-18"
SERVER_INFO = {"name": "team-brain", "version": "1.0.0"}

# Curated surface: the tools SKILL.md teaches, nothing exotic (no leases/mesh/
# sentinels against a shared brain). Descriptions and schemas mirror the shim so
# model-facing behavior matches the fleet bundle. Filled in by Task 2.
TOOLS: list[dict] = []
TOOL_NAMES = {t["name"] for t in TOOLS}


class ToolError(Exception):
    """Argument-validation failure — surfaced as an MCP tool error, not a 500."""


async def engine_call(am_base: str, secret: str, method: str, path: str,
                      payload: dict | None = None):
    """One REST call to the engine. Module-level so tests can monkeypatch it."""
    async with httpx.AsyncClient(timeout=60) as c:
        r = await c.request(method, f"{am_base}{path}", json=payload,
                            headers={"Authorization": f"Bearer {secret}"})
    r.raise_for_status()
    try:
        return r.json()
    except ValueError:
        return {"status": r.status_code, "body": r.text[:2000]}


async def call_tool(name: str, args: dict, am_base: str, secret: str, note_writes):
    raise ToolError(f"unknown tool: {name}")  # replaced in Task 2


def _tool_result(payload) -> dict:
    # /agentmemory/mcp/call already returns MCP-shaped {content:[...]}; pass it
    # through. Everything else gets wrapped the way the shim wraps it.
    if isinstance(payload, dict) and isinstance(payload.get("content"), list):
        return payload
    return {"content": [{"type": "text", "text": json.dumps(payload)}]}


def build_router(secret: str, am_base: str, note_writes) -> APIRouter:
    router = APIRouter()

    def _rpc(id_, **kv):
        return JSONResponse({"jsonrpc": "2.0", "id": id_, **kv})

    def _err(id_, code, msg):
        return _rpc(id_, error={"code": code, "message": msg})

    @router.post("/mcp")
    async def mcp(request: Request):
        auth = request.headers.get("authorization")
        if secret and auth != f"Bearer {secret}" \
                and request.query_params.get("key") != secret:
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        try:
            msg = json.loads(await request.body() or b"null")
        except ValueError:
            return _err(None, -32700, "parse error")
        if not isinstance(msg, dict):
            return _err(None, -32600, "batch requests not supported")
        method = msg.get("method")
        msg_id = msg.get("id")
        params = msg.get("params") or {}
        if msg_id is None:  # notification (e.g. notifications/initialized)
            return Response(status_code=202)
        if method == "initialize":
            ver = params.get("protocolVersion")
            return _rpc(msg_id, result={
                "protocolVersion": ver if ver in PROTOCOL_VERSIONS else LATEST_PROTOCOL,
                "capabilities": {"tools": {}},
                "serverInfo": SERVER_INFO})
        if method == "ping":
            return _rpc(msg_id, result={})
        if method == "tools/list":
            return _rpc(msg_id, result={"tools": TOOLS})
        if method == "tools/call":
            name = params.get("name")
            if name not in TOOL_NAMES:
                return _err(msg_id, -32602, f"unknown tool: {name}")
            try:
                payload = await call_tool(name, params.get("arguments") or {},
                                          am_base, secret, note_writes)
            except ToolError as e:
                return _rpc(msg_id, result={
                    "isError": True, "content": [{"type": "text", "text": str(e)}]})
            except Exception as e:  # noqa: BLE001 — engine down/HTTP error: the
                # model must see it (this visibility is the whole point vs the shim)
                return _rpc(msg_id, result={
                    "isError": True,
                    "content": [{"type": "text", "text": f"team brain call failed: {e}"}]})
            return _rpc(msg_id, result=_tool_result(payload))
        return _err(msg_id, -32601, f"method not found: {method}")

    @router.api_route("/mcp", methods=["GET", "DELETE"])
    async def mcp_no_stream():
        return Response(status_code=405)

    return router
```

- [ ] **Step 5: Run protocol tests to verify they pass**

```bash
cd /home/sprite/podbrain/server/gateway && python3 -m pytest test_mcp_endpoint.py -q
```

Expected: 8 passed.

- [ ] **Step 6: Commit**

```bash
cd /home/sprite/podbrain && git add server/gateway/mcp_endpoint.py server/gateway/test_mcp_endpoint.py
git commit -m "gateway: MCP-over-HTTP protocol layer (stateless streamable HTTP, no tools yet)"
```

---

### Task 2: Tool table + dispatch to the engine REST API

**Files:**
- Modify: `server/gateway/mcp_endpoint.py` (replace the `TOOLS = []` placeholder and the stub `call_tool`)
- Modify: `server/gateway/test_mcp_endpoint.py` (append tests)

- [ ] **Step 1: Write the failing tool tests** (append to `test_mcp_endpoint.py`)

```python
def test_tools_list_has_curated_surface(harness):
    client, _, _ = harness
    names = {t["name"] for t in rpc(client, "tools/list").json()["result"]["tools"]}
    assert names == {
        "memory_save", "memory_recall", "memory_smart_search", "memory_sessions",
        "memory_export", "memory_audit", "memory_governance_delete",
        "memory_consolidate", "memory_snapshot_create"}
    for t in rpc(client, "tools/list").json()["result"]["tools"]:
        assert t["description"] and t["inputSchema"]["type"] == "object"


def test_save_maps_to_remember_and_counts_write(harness):
    client, calls, writes = harness
    r = rpc(client, "tools/call", {"name": "memory_save", "arguments": {
        "content": "We use Postgres", "type": "decision", "concepts": "db, infra"}})
    assert calls == [{"method": "POST", "path": "/agentmemory/remember",
                      "payload": {"content": "We use Postgres", "type": "decision",
                                  "concepts": ["db", "infra"], "files": []}}]
    assert writes == [1]
    content = r.json()["result"]["content"]
    assert content[0]["type"] == "text" and '"ok": true' in content[0]["text"]


def test_save_without_content_is_tool_error(harness):
    client, calls, writes = harness
    r = rpc(client, "tools/call", {"name": "memory_save", "arguments": {}})
    assert r.json()["result"]["isError"] is True
    assert calls == [] and writes == []


def test_recall_and_smart_search_paths(harness):
    client, calls, _ = harness
    rpc(client, "tools/call", {"name": "memory_recall",
                               "arguments": {"query": "auth", "limit": 5}})
    rpc(client, "tools/call", {"name": "memory_smart_search",
                               "arguments": {"query": "auth"}})
    assert calls[0]["path"] == "/agentmemory/search"
    assert calls[0]["payload"] == {"query": "auth", "limit": 5, "format": "full"}
    assert calls[1]["path"] == "/agentmemory/smart-search"
    assert calls[1]["payload"] == {"query": "auth", "limit": 10}


def test_limit_is_clamped(harness):
    client, calls, _ = harness
    rpc(client, "tools/call", {"name": "memory_recall",
                               "arguments": {"query": "x", "limit": 9999}})
    assert calls[0]["payload"]["limit"] == 100


def test_get_tools_and_governance_delete(harness):
    client, calls, _ = harness
    rpc(client, "tools/call", {"name": "memory_sessions", "arguments": {}})
    rpc(client, "tools/call", {"name": "memory_audit", "arguments": {"limit": 7}})
    rpc(client, "tools/call", {"name": "memory_export", "arguments": {}})
    rpc(client, "tools/call", {"name": "memory_governance_delete",
                               "arguments": {"memoryIds": "a1, b2", "reason": "dupes"}})
    assert [c["path"] for c in calls[:3]] == [
        "/agentmemory/sessions?limit=20", "/agentmemory/audit?limit=7",
        "/agentmemory/export"]
    assert calls[3] == {"method": "DELETE", "path": "/agentmemory/governance/memories",
                        "payload": {"memoryIds": ["a1", "b2"], "reason": "dupes"}}


def test_generic_tools_go_via_mcp_call_and_pass_through(harness, monkeypatch):
    client, calls, _ = harness

    async def mcp_shaped(am_base, secret, method, path, payload=None):
        calls.append({"method": method, "path": path, "payload": payload})
        return {"content": [{"type": "text", "text": "done"}]}

    monkeypatch.setattr(mcp_endpoint, "engine_call", mcp_shaped)
    r = rpc(client, "tools/call", {"name": "memory_consolidate",
                                   "arguments": {"tier": "semantic"}})
    assert calls[-1] == {"method": "POST", "path": "/agentmemory/mcp/call",
                         "payload": {"name": "memory_consolidate",
                                     "arguments": {"tier": "semantic"}}}
    assert r.json()["result"] == {"content": [{"type": "text", "text": "done"}]}


def test_unknown_tool_is_invalid_params(harness):
    client, _, _ = harness
    r = rpc(client, "tools/call", {"name": "memory_mesh_sync", "arguments": {}})
    assert r.json()["error"]["code"] == -32602


def test_engine_failure_is_visible_tool_error(harness, monkeypatch):
    client, _, _ = harness

    async def boom(am_base, secret, method, path, payload=None):
        raise httpx.ConnectError("connection refused")

    import httpx
    monkeypatch.setattr(mcp_endpoint, "engine_call", boom)
    r = rpc(client, "tools/call", {"name": "memory_smart_search",
                                   "arguments": {"query": "x"}})
    body = r.json()["result"]
    assert body["isError"] is True
    assert "team brain call failed" in body["content"][0]["text"]
```

Note: move the `import httpx` in the last test to the top of the file with the other imports when writing it.

- [ ] **Step 2: Run tests to verify the new ones fail**

```bash
cd /home/sprite/podbrain/server/gateway && python3 -m pytest test_mcp_endpoint.py -q
```

Expected: the 8 protocol tests pass; the 9 new ones fail (empty `TOOLS`, stub `call_tool`).

- [ ] **Step 3: Implement the tool table and dispatch**

In `mcp_endpoint.py`, replace `TOOLS: list[dict] = []` with (schemas mirror the shim's `CORE_TOOLS`/`V040_TOOLS`, minus upstream's `project` param which proxy mode ignores anyway):

```python
def _t(name, description, properties, required=None):
    schema = {"type": "object", "properties": properties}
    if required:
        schema["required"] = required
    return {"name": name, "description": description, "inputSchema": schema}


_STR = lambda d: {"type": "string", "description": d}   # noqa: E731
_NUM = lambda d: {"type": "number", "description": d}   # noqa: E731

TOOLS = [
    _t("memory_save",
       "Explicitly save an important insight, decision, or pattern to long-term memory.",
       {"content": _STR("The insight or decision to remember"),
        "type": _STR("Memory type: pattern, preference, architecture, bug, workflow, or fact"),
        "concepts": _STR("Comma-separated key concepts"),
        "files": _STR("Comma-separated relevant file paths")},
       required=["content"]),
    _t("memory_recall",
       "Search past session observations for relevant context. Use when you need to "
       "recall what happened in previous sessions, find past decisions, or look up "
       "how a file was modified before.",
       {"query": _STR("Search query (keywords, file names, concepts)"),
        "limit": _NUM("Max results to return (default 10)"),
        "format": _STR("Result format: full, compact, or narrative (default full)"),
        "token_budget": _NUM("Optional token budget to trim returned results")},
       required=["query"]),
    _t("memory_smart_search",
       "Hybrid semantic+keyword search with progressive disclosure.",
       {"query": _STR("Search query"),
        "expandIds": _STR("Comma-separated observation IDs to expand"),
        "limit": _NUM("Max results (default 10)")},
       required=["query"]),
    _t("memory_sessions",
       "List recent sessions with their status and observation counts.",
       {"limit": _NUM("Max sessions (default 20)")}),
    _t("memory_export", "Export all memory data as JSON.", {}),
    _t("memory_audit",
       "View the audit trail of memory operations.",
       {"operation": _STR("Filter by operation type"),
        "limit": _NUM("Max entries (default 50)")}),
    _t("memory_governance_delete",
       "Delete specific memories with audit trail.",
       {"memoryIds": _STR("Comma-separated memory IDs to delete"),
        "reason": _STR("Reason for deletion")},
       required=["memoryIds"]),
    _t("memory_consolidate",
       "Run the 4-tier memory consolidation pipeline (working -> episodic -> "
       "semantic -> procedural).",
       {"tier": _STR("Target tier: episodic, semantic, or procedural")}),
    _t("memory_snapshot_create",
       "Create a git-versioned snapshot of current memory state.",
       {"message": _STR("Snapshot description")}),
]
TOOL_NAMES = {t["name"] for t in TOOLS}
# These have no dedicated REST endpoint — they ride the engine's generic
# /agentmemory/mcp/call, like the shim's non-core tools do.
GENERIC_TOOLS = {"memory_consolidate", "memory_snapshot_create"}
```

and replace the stub `call_tool` with:

```python
def _norm_list(v):
    """Comma-string or array -> trimmed list (mirrors the shim's normalizeList)."""
    if isinstance(v, list):
        return [s.strip() for s in v if isinstance(s, str) and s.strip()]
    if isinstance(v, str):
        return [s.strip() for s in v.split(",") if s.strip()]
    return []


def _limit(v, fallback=10):
    try:
        n = int(float(v))
    except (TypeError, ValueError):
        return fallback
    return min(n, 100) if n > 0 else fallback


async def call_tool(name: str, args: dict, am_base: str, secret: str, note_writes):
    if name == "memory_save":
        content = (args.get("content") or "").strip()
        if not content:
            raise ToolError("content is required")
        out = await engine_call(am_base, secret, "POST", "/agentmemory/remember", {
            "content": content, "type": args.get("type") or "fact",
            "concepts": _norm_list(args.get("concepts")),
            "files": _norm_list(args.get("files"))})
        note_writes(1)  # feeds the activity-triggered cataloger, like /agentmemory/remember
        return out
    if name in ("memory_recall", "memory_smart_search"):
        query = (args.get("query") or "").strip()
        if not query:
            raise ToolError("query is required")
        payload = {"query": query, "limit": _limit(args.get("limit"))}
        if name == "memory_recall":
            payload["format"] = args.get("format") or "full"
            path = "/agentmemory/search"
        else:
            if args.get("format"):
                payload["format"] = args["format"]
            path = "/agentmemory/smart-search"
        if args.get("token_budget"):
            payload["token_budget"] = args["token_budget"]
        return await engine_call(am_base, secret, "POST", path, payload)
    if name == "memory_sessions":
        return await engine_call(am_base, secret, "GET",
                                 f"/agentmemory/sessions?limit={_limit(args.get('limit'), 20)}")
    if name == "memory_export":
        return await engine_call(am_base, secret, "GET", "/agentmemory/export")
    if name == "memory_audit":
        return await engine_call(am_base, secret, "GET",
                                 f"/agentmemory/audit?limit={_limit(args.get('limit'), 50)}")
    if name == "memory_governance_delete":
        ids = _norm_list(args.get("memoryIds"))
        if not ids:
            raise ToolError("memoryIds is required")
        return await engine_call(am_base, secret, "DELETE",
                                 "/agentmemory/governance/memories",
                                 {"memoryIds": ids, "reason": args.get("reason") or "client request"})
    # GENERIC_TOOLS: the engine's own MCP dispatcher handles them.
    return await engine_call(am_base, secret, "POST", "/agentmemory/mcp/call",
                             {"name": name, "arguments": args})
```

- [ ] **Step 4: Run the full suite**

```bash
cd /home/sprite/podbrain/server/gateway && python3 -m pytest test_mcp_endpoint.py -q
```

Expected: 17 passed.

- [ ] **Step 5: Commit**

```bash
cd /home/sprite/podbrain && git add server/gateway/mcp_endpoint.py server/gateway/test_mcp_endpoint.py
git commit -m "gateway: curated 9-tool MCP surface dispatching to the engine REST API"
```

---

### Task 3: Mount in the gateway app

**Files:**
- Modify: `server/gateway/app.py` (import near the top; mount after `note_writes`, i.e. right above the `# ---------- endpoints ----------` divider at ~line 220)

- [ ] **Step 1: Add the import and mount**

In `app.py`, after the existing imports (below `from fastapi.responses import …`):

```python
from mcp_endpoint import build_router as build_mcp_router
```

After the `note_writes` function definition (just above `# ---------- endpoints ----------`):

```python
# MCP-over-HTTP: the keyless client surface (Claude Code plugin / remote
# connectors). Mounted here so memory_save shares the cataloger write counter.
app.include_router(build_mcp_router(SECRET, AM_BASE, note_writes))
```

- [ ] **Step 2: Verify the app imports and the route exists**

```bash
cd /home/sprite/podbrain/server/gateway && python3 -c "
import app
routes = {(r.path, tuple(sorted(r.methods))) for r in app.app.routes if hasattr(r, 'methods')}
assert ('/mcp', ('POST',)) in routes, routes
assert ('/mcp', ('DELETE', 'GET')) in routes, routes
print('mounted ok')"
```

Expected: `mounted ok`.

- [ ] **Step 3: Commit**

```bash
cd /home/sprite/podbrain && git add server/gateway/app.py
git commit -m "gateway: mount /mcp endpoint"
```

---

### Task 4: Deploy on this brain box and verify live (curl level)

**Files:** none (operational)

- [ ] **Step 1: Restart the gateway service and confirm health**

```bash
sprite-env services restart team-brain && sleep 2 && curl -s localhost:8080/healthz
```

Expected: `{"status":"ok","service":"team-brain-gateway"}`

- [ ] **Step 2: initialize + tools/list against the live gateway**

```bash
S=$(cat ~/.agentmemory/team_secret.txt)
curl -s localhost:8080/mcp -H "Authorization: Bearer $S" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
curl -s localhost:8080/mcp -H "Authorization: Bearer $S" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | python3 -c 'import sys,json;print([t["name"] for t in json.load(sys.stdin)["result"]["tools"]])'
```

Expected: an `initialize` result with `"serverInfo": {"name": "team-brain"…}`, then the 9 tool names.

- [ ] **Step 3: Live tool call against the real engine**

```bash
curl -s localhost:8080/mcp -H "Authorization: Bearer $S" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"memory_smart_search","arguments":{"query":"postgres","limit":3}}}' | head -c 600
```

Expected: a `result.content[0].text` containing real search-result JSON (no `isError`).

- [ ] **Step 4: Verify auth failure modes**

```bash
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/mcp -d '{}'          # 401
curl -s localhost:8080/mcp -H "Authorization: Bearer $S" -d 'not json'       # -32700 parse error
```

- [ ] **Step 5: Commit nothing; checkpoint the box**

```bash
sprite-env checkpoints create --comment "gateway /mcp live"
```

---

### Task 5: End-to-end with a real Claude Code client (incl. cold-wake check)

**Files:** none (operational; uses a scratch dir so nothing touches repo or user config)

- [ ] **Step 1: Attach a real Claude Code to the endpoint (local scope, scratch dir)**

```bash
mkdir -p /tmp/mcp-e2e && cd /tmp/mcp-e2e && git init -q
S=$(cat ~/.agentmemory/team_secret.txt)
claude mcp add --transport http team-brain-e2e http://localhost:8080/mcp \
  --header "Authorization: Bearer $S" -s local
claude mcp list
```

Expected: `team-brain-e2e: http://localhost:8080/mcp (HTTP) - ✔ Connected`

- [ ] **Step 2: Round-trip through a real session**

```bash
cd /tmp/mcp-e2e && claude -p --model haiku \
  "Use the team-brain-e2e MCP memory_save tool to save exactly: 'mcp-e2e marker $(date +%s)'. Then use memory_smart_search to find 'mcp-e2e marker' and print the top result title verbatim."
```

Expected: output quotes the marker back; no errors. (This proves save+search through the full public path: Claude Code → gateway JSON-RPC → engine.)

- [ ] **Step 3: Verify the failure mode is VISIBLE (the whole point)**

```bash
sprite-env services stop agentmemory
cd /tmp/mcp-e2e && claude -p --model haiku \
  "Use the team-brain-e2e memory_smart_search tool with query 'anything' and report the exact error text if it fails."
sprite-env services start agentmemory
```

Expected: the model reports a "team brain call failed: …" tool error — NOT a fabricated success. Restart the engine afterward and re-run Step 2's search to confirm recovery.

- [ ] **Step 4: Cold-wake check (spec open question)**

From a machine OUTSIDE this box (or after letting the Sprite suspend), point `claude mcp add --transport http … https://<brain>.sprites.app/mcp --header …` at the public URL and run a first tool call against the suspended box. Record: does the first call succeed, time out, or need a retry? Note the result in `docs/DEVELOPING.md` Known limitations if flaky (mention `MCP_TIMEOUT`).

- [ ] **Step 5: Clean up the scratch client**

```bash
cd /tmp/mcp-e2e && claude mcp remove team-brain-e2e -s local && cd / && rm -rf /tmp/mcp-e2e
```

---

### Task 6: Document the endpoint

**Files:**
- Modify: `server/gateway/app.py:1-21` (the module docstring's route list)
- Modify: `docs/DEVELOPING.md` (the "The pieces" gateway bullet + drop/temper the silent-local-save limitation for HTTP-MCP clients)

- [ ] **Step 1: Add `/mcp` to the gateway docstring route list**

In `app.py`'s module docstring, after the `/agentmemory/*` line, add:

```
  /mcp                  POST: stateless MCP (Streamable HTTP) — the keyless client
                        surface; curated memory tools fulfilled via the engine REST
                        API (see mcp_endpoint.py)
```

- [ ] **Step 2: Update DEVELOPING.md**

In the gateway bullet under "The pieces", append: ", and `/mcp` (MCP-over-HTTP — clients and claude.ai connectors attach directly; no npx shim, so the shim's silent-local-fallback cannot occur on this path)". In the "Known limitations" silent-local-save bullet, append: "**Scope narrowed (2026-06):** only the Podclave fleet bundle still runs the shim; BYO clients use the gateway's `/mcp` endpoint, where a down brain is a visible tool error."

- [ ] **Step 3: Commit**

```bash
cd /home/sprite/podbrain && git add server/gateway/app.py docs/DEVELOPING.md
git commit -m "docs: /mcp endpoint in gateway docstring + DEVELOPING.md"
```
