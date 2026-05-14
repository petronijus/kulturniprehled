"""Watchlist CRUD tests — happy path, nesting cap, reorder, check, shared workspace."""

from __future__ import annotations

import pytest
from httpx import AsyncClient

from tests.conftest import auth_header, login_as


def _payload(**overrides: object) -> dict[str, object]:
    base: dict[str, object] = {
        "title": "Hlas mocných (Wenders)",
        "kind": "film",
    }
    base.update(overrides)
    return base


@pytest.mark.asyncio
async def test_create_root_item(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    created = await client.post("/v1/watchlist", json=_payload(), headers=headers)
    assert created.status_code == 201, created.text
    body = created.json()
    assert body["parent_id"] is None
    assert body["kind"] == "film"
    assert body["done"] is False
    assert body["version"] == 1
    assert body["position"] == pytest.approx(1.0)


@pytest.mark.asyncio
async def test_list_order_is_position_within_parent(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])

    a = (await client.post("/v1/watchlist", json=_payload(title="A"), headers=headers)).json()
    b = (await client.post("/v1/watchlist", json=_payload(title="B"), headers=headers)).json()
    parent = (
        await client.post(
            "/v1/watchlist",
            json=_payload(title="Godard", kind="film"),
            headers=headers,
        )
    ).json()
    c1 = (
        await client.post(
            "/v1/watchlist",
            json=_payload(title="Vivre sa vie", parent_id=parent["id"]),
            headers=headers,
        )
    ).json()
    c2 = (
        await client.post(
            "/v1/watchlist",
            json=_payload(title="Pierrot le Fou", parent_id=parent["id"]),
            headers=headers,
        )
    ).json()

    listing = (await client.get("/v1/watchlist", headers=headers)).json()
    ids = [r["id"] for r in listing["items"]]
    assert ids == [a["id"], b["id"], parent["id"], c1["id"], c2["id"]]


@pytest.mark.asyncio
async def test_two_level_depth_cap(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    parent = (
        await client.post("/v1/watchlist", json=_payload(title="Goal"), headers=headers)
    ).json()
    child = (
        await client.post(
            "/v1/watchlist",
            json=_payload(title="Step 1", parent_id=parent["id"]),
            headers=headers,
        )
    ).json()
    # Cannot attach a grandchild — server rejects.
    grand = await client.post(
        "/v1/watchlist",
        json=_payload(title="Substep", parent_id=child["id"]),
        headers=headers,
    )
    assert grand.status_code == 400
    assert grand.json()["detail"]["code"] == "max_depth_exceeded"


@pytest.mark.asyncio
async def test_check_marks_done_by(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    created = (
        await client.post("/v1/watchlist", json=_payload(), headers=headers)
    ).json()
    res = await client.post(
        f"/v1/watchlist/{created['id']}/check",
        json={"version": 1, "done": True},
        headers=headers,
    )
    assert res.status_code == 200
    body = res.json()
    assert body["done"] is True
    assert body["done_at"] is not None
    assert body["done_by"] is not None
    assert body["version"] == 2

    # Replay the same toggle — server short-circuits without bumping version.
    again = await client.post(
        f"/v1/watchlist/{created['id']}/check",
        json={"version": 2, "done": True},
        headers=headers,
    )
    assert again.status_code == 200
    assert again.json()["version"] == 2


@pytest.mark.asyncio
async def test_patch_requires_matching_version(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    created = (
        await client.post("/v1/watchlist", json=_payload(), headers=headers)
    ).json()
    stale = await client.patch(
        f"/v1/watchlist/{created['id']}",
        json={"version": 999, "title": "Nope"},
        headers=headers,
    )
    assert stale.status_code == 409
    fresh = await client.patch(
        f"/v1/watchlist/{created['id']}",
        json={"version": 1, "title": "Hlas mocných", "note": "kino Aero"},
        headers=headers,
    )
    assert fresh.status_code == 200
    body = fresh.json()
    assert body["title"] == "Hlas mocných"
    assert body["note"] == "kino Aero"
    assert body["version"] == 2


@pytest.mark.asyncio
async def test_move_reorders_within_parent(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    a = (await client.post("/v1/watchlist", json=_payload(title="A"), headers=headers)).json()
    b = (await client.post("/v1/watchlist", json=_payload(title="B"), headers=headers)).json()
    c = (await client.post("/v1/watchlist", json=_payload(title="C"), headers=headers)).json()

    # Move A to be after B → expected order: B, A, C.
    moved = await client.post(
        f"/v1/watchlist/{a['id']}/move",
        json={"version": 1, "after_id": b["id"]},
        headers=headers,
    )
    assert moved.status_code == 200
    listing = (await client.get("/v1/watchlist", headers=headers)).json()
    assert [r["title"] for r in listing["items"]] == ["B", "A", "C"]
    # Only the moved item's version changed.
    moved_versions = {r["id"]: r["version"] for r in listing["items"]}
    assert moved_versions[a["id"]] == 2
    assert moved_versions[b["id"]] == 1
    assert moved_versions[c["id"]] == 1


@pytest.mark.asyncio
async def test_move_reparents(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    parent = (
        await client.post("/v1/watchlist", json=_payload(title="Godard"), headers=headers)
    ).json()
    orphan = (
        await client.post("/v1/watchlist", json=_payload(title="Vivre sa vie"), headers=headers)
    ).json()

    moved = await client.post(
        f"/v1/watchlist/{orphan['id']}/move",
        json={"version": 1, "parent_id": parent["id"], "set_parent": True, "to_end": True},
        headers=headers,
    )
    assert moved.status_code == 200, moved.text
    assert moved.json()["parent_id"] == parent["id"]


@pytest.mark.asyncio
async def test_delete_parent_cascades_to_children(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    parent = (
        await client.post("/v1/watchlist", json=_payload(title="Godard"), headers=headers)
    ).json()
    child = (
        await client.post(
            "/v1/watchlist",
            json=_payload(title="Vivre sa vie", parent_id=parent["id"]),
            headers=headers,
        )
    ).json()

    deleted = await client.delete(f"/v1/watchlist/{parent['id']}", headers=headers)
    assert deleted.status_code == 204

    listing = (await client.get("/v1/watchlist", headers=headers)).json()
    ids = {r["id"] for r in listing["items"]}
    assert parent["id"] not in ids
    assert child["id"] not in ids


@pytest.mark.asyncio
async def test_shared_workspace_other_member_sees_items(client: AsyncClient) -> None:
    petr = await login_as(client, "petr@example.com")
    created = (
        await client.post(
            "/v1/watchlist",
            json=_payload(title="Joint film"),
            headers=auth_header(petr["access_token"]),
        )
    ).json()
    bela = await login_as(client, "bela@example.com")
    listing = await client.get(
        "/v1/watchlist", headers=auth_header(bela["access_token"])
    )
    assert listing.status_code == 200
    assert [r["id"] for r in listing.json()["items"]] == [created["id"]]
