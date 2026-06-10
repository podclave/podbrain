"""Tests for the gateway's MCP-over-HTTP endpoint. The engine is faked by
monkeypatching mcp_endpoint.engine_call, so these run with no engine present."""
import httpx
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


def test_wrong_credentials_rejected(harness):
    client, _, _ = harness
    assert rpc(client, "ping", headers={"Authorization": "Bearer wrong"}).status_code == 401
    r = client.post("/mcp?key=wrong", json={"jsonrpc": "2.0", "id": 1, "method": "ping", "params": {}})
    assert r.status_code == 401


def test_unauthenticated_notification_still_401(harness):
    client, _, _ = harness
    r = client.post("/mcp", json={"jsonrpc": "2.0", "method": "notifications/initialized"})
    assert r.status_code == 401


def test_parse_error(harness):
    client, _, _ = harness
    r = client.post("/mcp", headers=AUTH, content="not json")
    assert r.json()["error"]["code"] == -32700


def test_non_object_params_rejected(harness):
    client, _, _ = harness
    r = client.post("/mcp", headers=AUTH, json={
        "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [1]})
    assert r.json()["error"]["code"] == -32602


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

    monkeypatch.setattr(mcp_endpoint, "engine_call", boom)
    r = rpc(client, "tools/call", {"name": "memory_smart_search",
                                   "arguments": {"query": "x"}})
    body = r.json()["result"]
    assert body["isError"] is True
    assert "team brain call failed" in body["content"][0]["text"]
