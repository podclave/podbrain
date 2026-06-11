"""MCP-over-HTTP endpoint (stateless Streamable HTTP) for the team-brain gateway.

Speaks the MCP Streamable HTTP transport directly — one POST /mcp route handling
JSON-RPC — and fulfills tool calls against the agentmemory engine's REST API,
exactly as the @agentmemory/mcp stdio shim does in proxy mode.

Why this exists instead of clients running the npx shim:
  - no node prerequisite on clients;
  - the shim, on any failed proxy call, silently falls back to a throwaway local
    store AND REPORTS SUCCESS — here a down brain is a visible tool error;
  - claude.ai / Claude Desktop / Cowork can attach to the same URL as a remote
    connector (hence the ?key= auth fallback, mirroring /viewer?key=)
    (note: ?key= puts the secret in access logs — acceptable for the admin-grade
    shared secret, same tradeoff as /viewer?key=).

Stateless by design: every exposed tool is one request/response. No sessions, no
SSE stream, no server-initiated messages — so GET/DELETE return 405, which the
Streamable HTTP spec permits for servers that don't offer a stream.

Hand-rolled rather than the `mcp` pip package: the protocol subset we need is
four methods, and the gateway keeps its zero-new-deps posture.
"""
import hmac
import json

import httpx
from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, Response

PROTOCOL_VERSIONS = {"2024-11-05", "2025-03-26", "2025-06-18"}
LATEST_PROTOCOL = "2025-06-18"
SERVER_INFO = {"name": "team-brain", "version": "1.0.0"}

# Curated surface: the tools SKILL.md teaches, nothing exotic (no leases/mesh/
# sentinels against a shared brain). Descriptions and schemas mirror the shim so
# model-facing behavior matches the fleet bundle — EXCEPT two upstream params we
# deliberately omit rather than inherit: expandIds (smart_search) and operation
# (audit). Upstream advertises both but drops them in proxy mode, and the
# engine's own expansion path returns empty (verified live) — a model that uses
# an advertised-but-dead param burns a turn discovering it does nothing.
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
        "files": _STR("Comma-separated relevant file paths"),
        "project": _STR("Bare repo name this memory belongs to (the session-start "
                        "context announces it); omit when not repo-specific")},
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
       "Hybrid semantic+keyword search with progressive disclosure. For the full "
       "text of a truncated result, use memory_recall with format \"full\".",
       {"query": _STR("Search query"),
        "limit": _NUM("Max results (default 10)")},
       required=["query"]),
    _t("memory_sessions",
       "List recent sessions with their status and observation counts.",
       {"limit": _NUM("Max sessions (default 20)")}),
    _t("memory_export", "Export all memory data as JSON.", {}),
    _t("memory_audit",
       "View the audit trail of memory operations.",
       {"limit": _NUM("Max entries (default 50)")}),
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
# These have no dedicated REST endpoint — they ride the engine's generic
# /agentmemory/mcp/call, like the shim's non-core tools do.
GENERIC_TOOLS = {"memory_consolidate", "memory_snapshot_create"}


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


def _norm_list(v):
    """Comma-string or array -> trimmed list (mirrors the shim's normalizeList)."""
    if isinstance(v, list):
        return [s.strip() for s in v if isinstance(s, str) and s.strip()]
    if isinstance(v, str):
        return [s.strip() for s in v.split(",") if s.strip()]
    return []


def _pos_int(v):
    """Positive int from an int/float/numeric-str (never bool); else None."""
    if isinstance(v, bool) or not isinstance(v, (int, float, str)):
        return None
    try:
        n = int(float(v))
    except (ValueError, OverflowError):
        return None
    return n if n > 0 else None


def _limit(v, fallback=10):
    n = _pos_int(v)
    return min(n, 100) if n else fallback


async def call_tool(name: str, args: dict, am_base: str, secret: str, note_writes):
    if name == "memory_save":
        content = args.get("content")
        if not isinstance(content, str) or not content.strip():
            raise ToolError("content is required")
        content = content.strip()
        payload = {"content": content, "type": args.get("type") or "fact",
                   "concepts": _norm_list(args.get("concepts")),
                   "files": _norm_list(args.get("files"))}
        proj = args.get("project")
        if isinstance(proj, str) and proj.strip():
            payload["project"] = proj.strip()  # engine persists this natively
        out = await engine_call(am_base, secret, "POST", "/agentmemory/remember", payload)
        note_writes(1)  # feeds the activity-triggered cataloger, like /agentmemory/remember
        return out
    if name in ("memory_recall", "memory_smart_search"):
        query = args.get("query")
        if not isinstance(query, str) or not query.strip():
            raise ToolError("query is required")
        query = query.strip()
        payload = {"query": query, "limit": _limit(args.get("limit"))}
        fmt = args.get("format")
        fmt = fmt.strip().lower() if isinstance(fmt, str) and fmt.strip() else None
        if name == "memory_recall":
            payload["format"] = fmt or "full"
            path = "/agentmemory/search"
        else:
            if fmt:
                payload["format"] = fmt
            path = "/agentmemory/smart-search"
        tb = _pos_int(args.get("token_budget"))
        if tb:
            payload["token_budget"] = tb
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
    if name in GENERIC_TOOLS:
        # The engine's own MCP dispatcher handles these.
        return await engine_call(am_base, secret, "POST", "/agentmemory/mcp/call",
                                 {"name": name, "arguments": args})
    raise ToolError(f"unhandled tool: {name}")  # a TOOLS entry with no dispatch branch


def _tool_result(payload) -> dict:
    # /agentmemory/mcp/call already returns MCP-shaped {content:[...]}; pass it
    # through. Everything else gets wrapped the way the shim wraps it.
    if isinstance(payload, dict) and isinstance(payload.get("content"), list):
        return payload
    return {"content": [{"type": "text", "text": json.dumps(payload)}]}


def _eq(a, b):
    return hmac.compare_digest((a or "").encode(), b.encode())


def build_router(secret: str, am_base: str, note_writes) -> APIRouter:
    router = APIRouter()
    expected_auth = f"Bearer {secret}"

    def _rpc(id_, **kv):
        return JSONResponse({"jsonrpc": "2.0", "id": id_, **kv})

    def _err(id_, code, msg):
        return _rpc(id_, error={"code": code, "message": msg})

    @router.post("/mcp")
    async def mcp_post(request: Request):
        auth = request.headers.get("authorization")
        # no secret configured = fail open (dev) — mirrors app.py require_auth
        if secret and not (_eq(auth, expected_auth) or _eq(request.query_params.get("key"), secret)):
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        try:
            msg = json.loads(await request.body() or b"null")
        except ValueError:
            return _err(None, -32700, "parse error")
        if not isinstance(msg, dict):
            return _err(None, -32600, "request must be a single JSON-RPC object (batching not supported)")
        method = msg.get("method")
        msg_id = msg.get("id")
        params = msg.get("params") or {}
        if msg_id is None:  # notification (e.g. notifications/initialized)
            return Response(status_code=202)
        if not isinstance(params, dict):
            return _err(msg_id, -32602, "params must be an object")
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
            # membership checked against TOOLS directly — it is the ONLY gate keeping
            # the curated surface curated (the dispatch fallback forwards anything to the engine)
            if not any(t["name"] == name for t in TOOLS):
                return _err(msg_id, -32602, f"unknown tool: {name}")
            arguments = params.get("arguments") or {}
            if not isinstance(arguments, dict):
                return _err(msg_id, -32602, "arguments must be an object")
            try:
                payload = await call_tool(name, arguments,
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

    # No GET/DELETE handler on purpose: Starlette answers unmatched methods on a
    # matched path with 405, which is exactly the no-stream behavior we want.
    return router
