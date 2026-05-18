"""Events CRUD tests — happy path, version conflicts, soft-delete, shared workspace."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest
from httpx import AsyncClient

from tests.conftest import auth_header, login_as


def _event_payload(**overrides: object) -> dict[str, object]:
    base: dict[str, object] = {
        "title": "Nick Cave & The Bad Seeds",
        "category": "concert",
        "starts_at": (datetime.now(UTC) + timedelta(days=14)).isoformat().replace("+00:00", "Z"),
    }
    base.update(overrides)
    return base


@pytest.mark.asyncio
async def test_create_and_get_event(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    create = await client.post("/v1/events", json=_event_payload(), headers=headers)
    assert create.status_code == 201, create.text
    body = create.json()
    assert body["title"] == "Nick Cave & The Bad Seeds"
    assert body["version"] == 1
    assert body["status"] == "planned"
    assert body["source"] == "manual"

    fetched = await client.get(f"/v1/events/{body['id']}", headers=headers)
    assert fetched.status_code == 200
    assert fetched.json()["id"] == body["id"]


@pytest.mark.asyncio
async def test_request_image_upload_url_returns_presigned_put_and_public_get(
    client: AsyncClient,
) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    create = await client.post("/v1/events", json=_event_payload(), headers=headers)
    event_id = create.json()["id"]
    response = await client.post(
        f"/v1/events/{event_id}/images/upload-url",
        json={"kind": "cover", "extension": "jpg"},
        headers=headers,
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["upload_url"].startswith("http")
    # Public URL is path-style + lives under the images bucket so the
    # mobile app can fetch it without involving the API.
    assert f"/event-images/events/{event_id}/cover.jpg" in body["public_url"]
    assert body["expires_in_seconds"] > 0


@pytest.mark.asyncio
async def test_request_image_upload_url_rejects_unknown_kind(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    create = await client.post("/v1/events", json=_event_payload(), headers=headers)
    event_id = create.json()["id"]
    response = await client.post(
        f"/v1/events/{event_id}/images/upload-url",
        json={"kind": "ticket", "extension": "jpg"},
        headers=headers,
    )
    assert response.status_code == 422


@pytest.mark.asyncio
async def test_create_persists_image_urls_and_venue_address(client: AsyncClient) -> None:
    # Regression: the ingest skill was reporting these fields silently
    # disappearing from /v1/events POST responses — the schema accepted
    # them but the create handler wasn't passing them through to the ORM.
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    create = await client.post(
        "/v1/events",
        json=_event_payload(
            cover_image_url="https://example.com/cover.jpg",
            venue_image_url="https://example.com/venue.jpg",
            venue_address="Rudolfinum, Alšovo nábřeží 12, Praha 1",
        ),
        headers=headers,
    )
    assert create.status_code == 201, create.text
    body = create.json()
    assert body["cover_image_url"] == "https://example.com/cover.jpg"
    assert body["venue_image_url"] == "https://example.com/venue.jpg"
    assert body["venue_address"] == "Rudolfinum, Alšovo nábřeží 12, Praha 1"


@pytest.mark.asyncio
async def test_list_filters_by_date_and_category(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    now = datetime.now(UTC).replace(microsecond=0)
    await client.post(
        "/v1/events",
        json=_event_payload(
            title="Past concert",
            starts_at=(now - timedelta(days=30)).isoformat().replace("+00:00", "Z"),
        ),
        headers=headers,
    )
    await client.post(
        "/v1/events",
        json=_event_payload(
            title="Future film",
            category="cinema",
            starts_at=(now + timedelta(days=10)).isoformat().replace("+00:00", "Z"),
        ),
        headers=headers,
    )
    await client.post(
        "/v1/events",
        json=_event_payload(
            title="Future play",
            category="theatre",
            starts_at=(now + timedelta(days=20)).isoformat().replace("+00:00", "Z"),
        ),
        headers=headers,
    )

    upcoming = await client.get(
        "/v1/events",
        params={"starts_from": now.isoformat().replace("+00:00", "Z")},
        headers=headers,
    )
    assert upcoming.status_code == 200
    titles = [e["title"] for e in upcoming.json()["items"]]
    assert "Past concert" not in titles
    assert titles == ["Future film", "Future play"]

    cinema = await client.get("/v1/events", params={"category": "cinema"}, headers=headers)
    assert [e["title"] for e in cinema.json()["items"]] == ["Future film"]


@pytest.mark.asyncio
async def test_patch_requires_matching_version(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    created = (await client.post("/v1/events", json=_event_payload(), headers=headers)).json()
    event_id = created["id"]

    stale = await client.patch(
        f"/v1/events/{event_id}",
        json={"version": 999, "title": "New title"},
        headers=headers,
    )
    assert stale.status_code == 409
    assert stale.json()["detail"]["code"] == "version_mismatch"
    assert stale.json()["detail"]["current_version"] == 1

    fresh = await client.patch(
        f"/v1/events/{event_id}",
        json={"version": 1, "title": "Renamed", "status": "attended"},
        headers=headers,
    )
    assert fresh.status_code == 200
    body = fresh.json()
    assert body["title"] == "Renamed"
    assert body["status"] == "attended"
    assert body["version"] == 2


@pytest.mark.asyncio
async def test_delete_is_soft_and_hides_from_list(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    created = (await client.post("/v1/events", json=_event_payload(), headers=headers)).json()
    event_id = created["id"]

    deleted = await client.delete(f"/v1/events/{event_id}", headers=headers)
    assert deleted.status_code == 204

    listing = await client.get("/v1/events", headers=headers)
    assert listing.json()["items"] == []
    assert listing.json()["total"] == 0

    after_get = await client.get(f"/v1/events/{event_id}", headers=headers)
    assert after_get.status_code == 404


@pytest.mark.asyncio
async def test_shared_workspace_other_member_sees_event(client: AsyncClient) -> None:
    petr = await login_as(client, "petr@example.com")
    created = (
        await client.post(
            "/v1/events",
            json=_event_payload(title="Joint concert"),
            headers=auth_header(petr["access_token"]),
        )
    ).json()
    bela = await login_as(client, "bela@example.com")
    listing = await client.get("/v1/events", headers=auth_header(bela["access_token"]))
    assert listing.status_code == 200
    assert [e["id"] for e in listing.json()["items"]] == [created["id"]]
