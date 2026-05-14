"""Sync API tests: change_log pulls and outbox apply with idempotency."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
from httpx import AsyncClient

from tests.conftest import auth_header, login_as


def _iso(dt: datetime) -> str:
    return dt.isoformat().replace("+00:00", "Z")


def _future(days: int = 14) -> str:
    return _iso(datetime.now(UTC) + timedelta(days=days))


def _event_payload(**overrides: object) -> dict[str, object]:
    base: dict[str, object] = {
        "title": "PJ Harvey",
        "category": "concert",
        "starts_at": _future(),
    }
    base.update(overrides)
    return base


@pytest.mark.asyncio
async def test_crud_emits_change_log_entries(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])

    created = (await client.post("/v1/events", json=_event_payload(), headers=headers)).json()
    event_id = created["id"]

    await client.patch(
        f"/v1/events/{event_id}",
        json={"version": 1, "title": "Renamed"},
        headers=headers,
    )
    await client.delete(f"/v1/events/{event_id}", headers=headers)

    sync_response = await client.get("/v1/sync", headers=headers)
    assert sync_response.status_code == 200
    page = sync_response.json()
    ops = [(c["op"], c["payload"]["title"]) for c in page["changes"]]
    assert ops == [
        ("upsert", "PJ Harvey"),
        ("upsert", "Renamed"),
        ("delete", "Renamed"),
    ]
    assert page["has_more"] is False
    assert page["next_seq"] == page["changes"][-1]["seq"]


@pytest.mark.asyncio
async def test_sync_cursor_returns_only_newer_changes(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    await client.post("/v1/events", json=_event_payload(title="A"), headers=headers)
    first_pull = (await client.get("/v1/sync", headers=headers)).json()
    cursor = first_pull["next_seq"]

    await client.post("/v1/events", json=_event_payload(title="B"), headers=headers)
    await client.post("/v1/events", json=_event_payload(title="C"), headers=headers)

    delta = (await client.get(f"/v1/sync?since={cursor}", headers=headers)).json()
    titles = [c["payload"]["title"] for c in delta["changes"]]
    assert titles == ["B", "C"]


@pytest.mark.asyncio
async def test_sync_pagination_signals_more(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    for title in ("A", "B", "C"):
        await client.post("/v1/events", json=_event_payload(title=title), headers=headers)

    page = (await client.get("/v1/sync?limit=2", headers=headers)).json()
    assert len(page["changes"]) == 2
    assert page["has_more"] is True

    next_page = (
        await client.get(f"/v1/sync?since={page['next_seq']}&limit=2", headers=headers)
    ).json()
    assert [c["payload"]["title"] for c in next_page["changes"]] == ["C"]
    assert next_page["has_more"] is False


@pytest.mark.asyncio
async def test_apply_create_then_update_then_delete(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])

    create_op = {
        "op_id": str(uuid4()),
        "entity": "event",
        "op": "create",
        "payload": _event_payload(title="Outbox event"),
    }
    create_resp = await client.post(
        "/v1/sync/apply", json={"operations": [create_op]}, headers=headers
    )
    assert create_resp.status_code == 200
    [result] = create_resp.json()["results"]
    assert result["status"] == "applied"
    assert result["version"] == 1
    entity_id = result["entity_id"]

    update_op = {
        "op_id": str(uuid4()),
        "entity": "event",
        "op": "update",
        "entity_id": entity_id,
        "base_version": 1,
        "payload": {"title": "Outbox renamed"},
    }
    update_resp = await client.post(
        "/v1/sync/apply", json={"operations": [update_op]}, headers=headers
    )
    [update_result] = update_resp.json()["results"]
    assert update_result["status"] == "applied"
    assert update_result["version"] == 2

    delete_op = {
        "op_id": str(uuid4()),
        "entity": "event",
        "op": "delete",
        "entity_id": entity_id,
    }
    delete_resp = await client.post(
        "/v1/sync/apply", json={"operations": [delete_op]}, headers=headers
    )
    [delete_result] = delete_resp.json()["results"]
    assert delete_result["status"] == "applied"
    assert delete_result["version"] == 3


@pytest.mark.asyncio
async def test_apply_update_with_stale_version_returns_conflict(
    client: AsyncClient,
) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    created = (await client.post("/v1/events", json=_event_payload(), headers=headers)).json()

    op = {
        "op_id": str(uuid4()),
        "entity": "event",
        "op": "update",
        "entity_id": created["id"],
        "base_version": 99,
        "payload": {"title": "Should fail"},
    }
    response = await client.post("/v1/sync/apply", json={"operations": [op]}, headers=headers)
    [result] = response.json()["results"]
    assert result["status"] == "conflict"
    assert result["current_version"] == 1


@pytest.mark.asyncio
async def test_apply_is_idempotent_on_same_op_id(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    op_id = str(uuid4())
    payload = {
        "op_id": op_id,
        "entity": "event",
        "op": "create",
        "payload": _event_payload(title="Once"),
    }
    first = (
        await client.post("/v1/sync/apply", json={"operations": [payload]}, headers=headers)
    ).json()["results"][0]
    second = (
        await client.post("/v1/sync/apply", json={"operations": [payload]}, headers=headers)
    ).json()["results"][0]
    assert first == second

    # And only one event exists in the workspace.
    listing = (await client.get("/v1/events", headers=headers)).json()
    assert listing["total"] == 1


@pytest.mark.asyncio
async def test_apply_delete_on_already_deleted_is_idempotent_success(
    client: AsyncClient,
) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    created = (await client.post("/v1/events", json=_event_payload(), headers=headers)).json()
    await client.delete(f"/v1/events/{created['id']}", headers=headers)

    op = {
        "op_id": str(uuid4()),
        "entity": "event",
        "op": "delete",
        "entity_id": created["id"],
    }
    response = await client.post("/v1/sync/apply", json={"operations": [op]}, headers=headers)
    [result] = response.json()["results"]
    assert result["status"] == "applied"


@pytest.mark.asyncio
async def test_apply_unknown_entity_returns_not_found(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    op = {
        "op_id": str(uuid4()),
        "entity": "event",
        "op": "update",
        "entity_id": str(uuid4()),
        "base_version": 1,
        "payload": {"title": "Ghost"},
    }
    response = await client.post("/v1/sync/apply", json={"operations": [op]}, headers=headers)
    [result] = response.json()["results"]
    assert result["status"] == "not_found"


@pytest.mark.asyncio
async def test_apply_batch_continues_after_individual_failure(
    client: AsyncClient,
) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    bad = {
        "op_id": str(uuid4()),
        "entity": "event",
        "op": "update",
        "entity_id": str(uuid4()),
        "base_version": 1,
        "payload": {"title": "Ghost"},
    }
    good = {
        "op_id": str(uuid4()),
        "entity": "event",
        "op": "create",
        "payload": _event_payload(title="After failure"),
    }
    response = await client.post(
        "/v1/sync/apply",
        json={"operations": [bad, good]},
        headers=headers,
    )
    results = response.json()["results"]
    assert [r["status"] for r in results] == ["not_found", "applied"]


@pytest.mark.asyncio
async def test_sync_changes_appear_to_other_workspace_member(
    client: AsyncClient,
) -> None:
    petr = await login_as(client, "petr@example.com")
    await client.post(
        "/v1/events",
        json=_event_payload(title="Shared"),
        headers=auth_header(petr["access_token"]),
    )

    bela = await login_as(client, "bela@example.com")
    page = (await client.get("/v1/sync", headers=auth_header(bela["access_token"]))).json()
    assert [c["payload"]["title"] for c in page["changes"]] == ["Shared"]
