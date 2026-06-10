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
