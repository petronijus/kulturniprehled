"""End-to-end ticket lifecycle tests against real MinIO via testcontainers."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import httpx
import pytest
from httpx import AsyncClient

from tests.conftest import auth_header, login_as


def _future(days: int = 14) -> str:
    return (datetime.now(timezone.utc) + timedelta(days=days)).isoformat().replace(
        "+00:00", "Z"
    )


async def _create_event(client: AsyncClient, headers: dict[str, str]) -> dict[str, str]:
    response = await client.post(
        "/v1/events",
        json={"title": "Test event", "category": "concert", "starts_at": _future()},
        headers=headers,
    )
    assert response.status_code == 201, response.text
    return response.json()


async def _upload_blob(upload_url: str, content: bytes) -> None:
    # Talking to MinIO directly through the presigned URL — the request hits
    # the same host:port the API embedded in the signature.
    async with httpx.AsyncClient(timeout=10.0) as raw:
        response = await raw.put(upload_url, content=content)
    assert response.status_code in (200, 204), response.text


@pytest.mark.asyncio
async def test_upload_then_register_then_download(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    event = await _create_event(client, headers)

    upload = await client.post(
        "/v1/tickets/upload-url",
        json={
            "event_id": event["id"],
            "mime_type": "application/pdf",
            "original_filename": "ticket.pdf",
            "size_bytes": 16,
        },
        headers=headers,
    )
    assert upload.status_code == 201, upload.text
    upload_body = upload.json()
    assert upload_body["expires_in_seconds"] > 0

    await _upload_blob(upload_body["upload_url"], b"%PDF-1.4 fake-ticket")

    register = await client.post(
        "/v1/tickets",
        json={
            "event_id": event["id"],
            "object_key": upload_body["object_key"],
            "mime_type": "application/pdf",
            "original_filename": "ticket.pdf",
            "size_bytes": 19,
            "hash_sha256": "a" * 64,
        },
        headers=headers,
    )
    assert register.status_code == 201, register.text
    ticket = register.json()
    assert ticket["mime_type"] == "application/pdf"
    assert ticket["version"] == 1
    # `object_key` must not leak via the response — clients use the dedicated
    # URL endpoint instead.
    assert "object_key" not in ticket

    download = await client.get(f"/v1/tickets/{ticket['id']}/url", headers=headers)
    assert download.status_code == 200
    download_body = download.json()
    async with httpx.AsyncClient(timeout=10.0) as raw:
        fetched = await raw.get(download_body["download_url"])
    assert fetched.status_code == 200
    assert fetched.content == b"%PDF-1.4 fake-ticket"


@pytest.mark.asyncio
async def test_register_rejects_missing_object(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    event = await _create_event(client, headers)

    response = await client.post(
        "/v1/tickets",
        json={
            "event_id": event["id"],
            "object_key": "events/nope/never-uploaded",
            "mime_type": "application/pdf",
        },
        headers=headers,
    )
    assert response.status_code == 422
    assert "object not found" in response.text


@pytest.mark.asyncio
async def test_register_emits_change_log(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    event = await _create_event(client, headers)
    upload_body = (
        await client.post(
            "/v1/tickets/upload-url",
            json={"event_id": event["id"], "mime_type": "application/pdf"},
            headers=headers,
        )
    ).json()
    await _upload_blob(upload_body["upload_url"], b"blob")
    await client.post(
        "/v1/tickets",
        json={
            "event_id": event["id"],
            "object_key": upload_body["object_key"],
            "mime_type": "application/pdf",
        },
        headers=headers,
    )

    page = (await client.get("/v1/sync", headers=headers)).json()
    entity_types = [c["entity_type"] for c in page["changes"]]
    assert "ticket" in entity_types
    ticket_entries = [c for c in page["changes"] if c["entity_type"] == "ticket"]
    assert ticket_entries[-1]["op"] == "upsert"
    payload = ticket_entries[-1]["payload"]
    assert "object_key" not in payload  # see serialize_ticket
    assert payload["mime_type"] == "application/pdf"


@pytest.mark.asyncio
async def test_list_tickets_for_event_filters_soft_deleted(
    client: AsyncClient,
) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    event = await _create_event(client, headers)

    async def _register() -> dict[str, str]:
        upload_body = (
            await client.post(
                "/v1/tickets/upload-url",
                json={"event_id": event["id"], "mime_type": "image/png"},
                headers=headers,
            )
        ).json()
        await _upload_blob(upload_body["upload_url"], b"png-bytes")
        return (
            await client.post(
                "/v1/tickets",
                json={
                    "event_id": event["id"],
                    "object_key": upload_body["object_key"],
                    "mime_type": "image/png",
                },
                headers=headers,
            )
        ).json()

    first = await _register()
    second = await _register()

    listing = (
        await client.get(f"/v1/events/{event['id']}/tickets", headers=headers)
    ).json()
    assert {t["id"] for t in listing["items"]} == {first["id"], second["id"]}

    await client.delete(f"/v1/tickets/{first['id']}", headers=headers)
    after_delete = (
        await client.get(f"/v1/events/{event['id']}/tickets", headers=headers)
    ).json()
    assert [t["id"] for t in after_delete["items"]] == [second["id"]]


@pytest.mark.asyncio
async def test_delete_emits_delete_change_log(client: AsyncClient) -> None:
    pair = await login_as(client, "petr@example.com")
    headers = auth_header(pair["access_token"])
    event = await _create_event(client, headers)
    upload_body = (
        await client.post(
            "/v1/tickets/upload-url",
            json={"event_id": event["id"], "mime_type": "application/pdf"},
            headers=headers,
        )
    ).json()
    await _upload_blob(upload_body["upload_url"], b"x")
    ticket = (
        await client.post(
            "/v1/tickets",
            json={
                "event_id": event["id"],
                "object_key": upload_body["object_key"],
                "mime_type": "application/pdf",
            },
            headers=headers,
        )
    ).json()
    await client.delete(f"/v1/tickets/{ticket['id']}", headers=headers)

    page = (await client.get("/v1/sync", headers=headers)).json()
    ticket_entries = [c for c in page["changes"] if c["entity_type"] == "ticket"]
    assert [e["op"] for e in ticket_entries[-2:]] == ["upsert", "delete"]


@pytest.mark.asyncio
async def test_other_member_sees_ticket_via_sync(client: AsyncClient) -> None:
    petr = await login_as(client, "petr@example.com")
    petr_headers = auth_header(petr["access_token"])
    event = await _create_event(client, petr_headers)
    upload_body = (
        await client.post(
            "/v1/tickets/upload-url",
            json={"event_id": event["id"], "mime_type": "application/pdf"},
            headers=petr_headers,
        )
    ).json()
    await _upload_blob(upload_body["upload_url"], b"shared")
    ticket = (
        await client.post(
            "/v1/tickets",
            json={
                "event_id": event["id"],
                "object_key": upload_body["object_key"],
                "mime_type": "application/pdf",
            },
            headers=petr_headers,
        )
    ).json()

    bela = await login_as(client, "bela@example.com")
    bela_headers = auth_header(bela["access_token"])
    page = (await client.get("/v1/sync", headers=bela_headers)).json()
    assert any(
        c["entity_id"] == ticket["id"] for c in page["changes"] if c["entity_type"] == "ticket"
    )

    download = await client.get(
        f"/v1/tickets/{ticket['id']}/url", headers=bela_headers
    )
    assert download.status_code == 200
