"""Sync apply tests for the watchlist_item entity."""

from __future__ import annotations

from typing import Any
from uuid import uuid4

import pytest
from httpx import AsyncClient

from tests.conftest import auth_header, login_as


def _create_op(**payload_overrides: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {"title": "Godard", "kind": "film"}
    payload.update(payload_overrides)
    return {
        "op_id": str(uuid4()),
        "entity": "watchlist_item",
        "op": "create",
        "payload": payload,
    }


async def _apply(
    client: AsyncClient,
    headers: dict[str, str],
    ops: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    response = await client.post("/v1/sync/apply", json={"operations": ops}, headers=headers)
    assert response.status_code == 200, response.text
    return response.json()["results"]


@pytest.mark.asyncio
async def test_watchlist_create_update_delete_chain(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])

    [created] = await _apply(client, headers, [_create_op()])
    assert created["status"] == "applied"
    assert created["version"] == 1
    entity_id = created["entity_id"]

    [updated] = await _apply(
        client,
        headers,
        [
            {
                "op_id": str(uuid4()),
                "entity": "watchlist_item",
                "op": "update",
                "entity_id": entity_id,
                "base_version": 1,
                "payload": {"title": "Godard retrospektiva", "note": "v Aeru"},
            }
        ],
    )
    assert updated["status"] == "applied"
    assert updated["version"] == 2

    [deleted] = await _apply(
        client,
        headers,
        [
            {
                "op_id": str(uuid4()),
                "entity": "watchlist_item",
                "op": "delete",
                "entity_id": entity_id,
            }
        ],
    )
    assert deleted["status"] == "applied"
    assert deleted["version"] == 3

    # Confirm soft-delete via the REST list endpoint (filters tombstones).
    listing = (await client.get("/v1/watchlist", headers=headers)).json()
    assert listing["items"] == []


@pytest.mark.asyncio
async def test_watchlist_update_with_stale_version_returns_conflict(
    client: AsyncClient,
) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    [created] = await _apply(client, headers, [_create_op()])

    [result] = await _apply(
        client,
        headers,
        [
            {
                "op_id": str(uuid4()),
                "entity": "watchlist_item",
                "op": "update",
                "entity_id": created["entity_id"],
                "base_version": 99,
                "payload": {"title": "stale"},
            }
        ],
    )
    assert result["status"] == "conflict"
    assert result["current_version"] == 1


@pytest.mark.asyncio
async def test_watchlist_update_unknown_entity_returns_not_found(
    client: AsyncClient,
) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    [result] = await _apply(
        client,
        headers,
        [
            {
                "op_id": str(uuid4()),
                "entity": "watchlist_item",
                "op": "update",
                "entity_id": str(uuid4()),
                "base_version": 1,
                "payload": {"title": "phantom"},
            }
        ],
    )
    assert result["status"] == "not_found"


@pytest.mark.asyncio
async def test_watchlist_update_toggles_done_with_audit_fields(
    client: AsyncClient,
) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    [created] = await _apply(client, headers, [_create_op()])

    [done_result] = await _apply(
        client,
        headers,
        [
            {
                "op_id": str(uuid4()),
                "entity": "watchlist_item",
                "op": "update",
                "entity_id": created["entity_id"],
                "base_version": 1,
                "payload": {"done": True},
            }
        ],
    )
    assert done_result["status"] == "applied"
    assert done_result["version"] == 2

    listing = (await client.get("/v1/watchlist", headers=headers)).json()
    [item] = listing["items"]
    assert item["done"] is True
    assert item["done_at"] is not None
    assert item["done_by"] is not None


@pytest.mark.asyncio
async def test_watchlist_create_with_client_suggested_id(
    client: AsyncClient,
) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    suggested = str(uuid4())
    [result] = await _apply(
        client,
        headers,
        [
            {
                "op_id": str(uuid4()),
                "entity": "watchlist_item",
                "op": "create",
                "entity_id": suggested,
                "payload": {"title": "Suggested id", "kind": "film"},
            }
        ],
    )
    assert result["status"] == "applied"
    assert result["entity_id"] == suggested


@pytest.mark.asyncio
async def test_watchlist_move_reorders_within_scope(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    [a] = await _apply(client, headers, [_create_op(title="A")])
    [b] = await _apply(client, headers, [_create_op(title="B")])
    [c] = await _apply(client, headers, [_create_op(title="C")])

    [move_result] = await _apply(
        client,
        headers,
        [
            {
                "op_id": str(uuid4()),
                "entity": "watchlist_item",
                "op": "move",
                "entity_id": c["entity_id"],
                "base_version": 1,
                "payload": {"before_id": a["entity_id"]},
            }
        ],
    )
    assert move_result["status"] == "applied"
    assert move_result["version"] == 2

    listing = (await client.get("/v1/watchlist", headers=headers)).json()
    titles = [item["title"] for item in listing["items"]]
    assert titles == ["C", "A", "B"]
    _ = b  # binding silences unused warning while keeping intent in the test


@pytest.mark.asyncio
async def test_watchlist_move_reparents_into_existing_parent(
    client: AsyncClient,
) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    [parent] = await _apply(client, headers, [_create_op(title="Godard")])
    [orphan] = await _apply(client, headers, [_create_op(title="Pierrot le Fou")])

    [move_result] = await _apply(
        client,
        headers,
        [
            {
                "op_id": str(uuid4()),
                "entity": "watchlist_item",
                "op": "move",
                "entity_id": orphan["entity_id"],
                "base_version": 1,
                "payload": {"parent_id": parent["entity_id"], "set_parent": True},
            }
        ],
    )
    assert move_result["status"] == "applied"

    listing = (await client.get("/v1/watchlist", headers=headers)).json()
    by_id = {item["id"]: item for item in listing["items"]}
    assert by_id[orphan["entity_id"]]["parent_id"] == parent["entity_id"]


@pytest.mark.asyncio
async def test_watchlist_move_refuses_to_nest_two_levels(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    [a] = await _apply(client, headers, [_create_op(title="A")])
    [b] = await _apply(client, headers, [_create_op(title="B")])
    # Make B a child of A.
    await _apply(
        client,
        headers,
        [
            {
                "op_id": str(uuid4()),
                "entity": "watchlist_item",
                "op": "move",
                "entity_id": b["entity_id"],
                "base_version": 1,
                "payload": {"parent_id": a["entity_id"], "set_parent": True},
            }
        ],
    )
    [c] = await _apply(client, headers, [_create_op(title="C")])
    # Now try to reparent C under B — B is already a child, so this should fail.
    [result] = await _apply(
        client,
        headers,
        [
            {
                "op_id": str(uuid4()),
                "entity": "watchlist_item",
                "op": "move",
                "entity_id": c["entity_id"],
                "base_version": 1,
                "payload": {"parent_id": b["entity_id"], "set_parent": True},
            }
        ],
    )
    assert result["status"] == "invalid"


@pytest.mark.asyncio
async def test_watchlist_delete_cascades_to_children(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    [parent] = await _apply(client, headers, [_create_op(title="Godard")])
    [child] = await _apply(
        client,
        headers,
        [_create_op(title="Pierrot", parent_id=parent["entity_id"])],
    )

    [delete_result] = await _apply(
        client,
        headers,
        [
            {
                "op_id": str(uuid4()),
                "entity": "watchlist_item",
                "op": "delete",
                "entity_id": parent["entity_id"],
            }
        ],
    )
    assert delete_result["status"] == "applied"

    listing = (await client.get("/v1/watchlist", headers=headers)).json()
    assert listing["items"] == []
    _ = child  # child existence is implicit in the empty listing above


@pytest.mark.asyncio
async def test_watchlist_delete_on_already_deleted_is_idempotent_success(
    client: AsyncClient,
) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    [created] = await _apply(client, headers, [_create_op()])
    await client.delete(f"/v1/watchlist/{created['entity_id']}", headers=headers)

    [result] = await _apply(
        client,
        headers,
        [
            {
                "op_id": str(uuid4()),
                "entity": "watchlist_item",
                "op": "delete",
                "entity_id": created["entity_id"],
            }
        ],
    )
    assert result["status"] == "applied"


@pytest.mark.asyncio
async def test_watchlist_apply_is_idempotent_on_same_op_id(
    client: AsyncClient,
) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    op = _create_op(title="Only once")

    first = (await _apply(client, headers, [op]))[0]
    second = (await _apply(client, headers, [op]))[0]
    assert first == second

    listing = (await client.get("/v1/watchlist", headers=headers)).json()
    assert len(listing["items"]) == 1
