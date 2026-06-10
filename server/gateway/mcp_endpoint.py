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
    (note: ?key= puts the secret in access logs — acceptable for the admin-grade shared secret, same tradeoff as /viewer?key=).

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
# model-facing behavior matches the fleet bundle. Filled in by Task 2.
TOOLS: list[dict] = []


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


def _eq(a, b):
    return hmac.compare_digest((a or "").encode(), b.encode())


def build_router(secret: str, am_base: str, note_writes) -> APIRouter:
    router = APIRouter()

    def _rpc(id_, **kv):
        return JSONResponse({"jsonrpc": "2.0", "id": id_, **kv})

    def _err(id_, code, msg):
        return _rpc(id_, error={"code": code, "message": msg})

    @router.post("/mcp")
    async def mcp_post(request: Request):
        auth = request.headers.get("authorization")
        if secret and not (_eq(auth, f"Bearer {secret}") or _eq(request.query_params.get("key"), secret)):  # no secret configured = fail open (dev) — mirrors app.py require_auth
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
            # membership checked against TOOLS directly — it is the ONLY gate keeping the curated surface curated (the dispatch fallback forwards anything to the engine)
            if not any(t["name"] == name for t in TOOLS):
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
