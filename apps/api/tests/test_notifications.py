"""Event notifications: what produces one, how they merge, how they sync."""

from __future__ import annotations

import asyncio
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID, uuid4

import pytest
from alembic import command
from alembic.config import Config as AlembicConfig
from httpx import AsyncClient
from sqlalchemy import func, inspect, select, update
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from kp_api.domain.enums import NotificationChange, NotificationKind
from kp_api.domain.models import Event, EventNotification
from kp_api.notifications import COALESCE_WINDOW, EventGone, announce, db_clock
from tests.conftest import API_DIR, auth_header, login_as


def _iso(dt: datetime) -> str:
    return dt.isoformat().replace("+00:00", "Z")


def _event_payload(**overrides: object) -> dict[str, object]:
    base: dict[str, object] = {
        "title": "Pelléas et Mélisande",
        "category": "concert",
        "starts_at": _iso(datetime.now(UTC) + timedelta(days=5)),
        "notes": "Debussy",
        "venue_address": "Národní divadlo, Praha",
    }
    base.update(overrides)
    return base


async def _headers(client: AsyncClient, email: str = "petr@example.com") -> dict[str, str]:
    pair = await login_as(client, email)
    return auth_header(pair["access_token"])


async def _notification_changes(
    client: AsyncClient, headers: dict[str, str]
) -> list[dict[str, Any]]:
    page = (await client.get("/v1/sync", headers=headers)).json()
    return [c for c in page["changes"] if c["entity_type"] == "notification"]


def _latest(changes: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """The last payload per notification id, as a phone would hold it."""

    out: dict[str, dict[str, Any]] = {}
    for change in changes:
        out[change["entity_id"]] = change["payload"]
    return out


async def _expire_pending(db_session: AsyncSession) -> None:
    await db_session.execute(
        update(EventNotification).values(deliver_after=datetime.now(UTC) - timedelta(seconds=1))
    )
    await db_session.commit()


async def _create_event(client: AsyncClient, headers: dict[str, str]) -> dict[str, Any]:
    response = await client.post("/v1/events", json=_event_payload(), headers=headers)
    assert response.status_code == 201, response.text
    body: dict[str, Any] = response.json()
    return body


@pytest.mark.asyncio
async def test_create_event_announces_it_after_the_coalescing_window(
    client: AsyncClient,
) -> None:
    headers = await _headers(client)
    before = datetime.now(UTC)
    event = await _create_event(client, headers)

    notifications = _latest(await _notification_changes(client, headers))
    assert len(notifications) == 1
    (payload,) = notifications.values()
    assert payload["event_id"] == event["id"]
    assert payload["kind"] == "event_created"
    assert payload["changes"] == []
    assert payload["created_by"] == event["created_by"]
    deliver_after = datetime.fromisoformat(payload["deliver_after"])
    assert deliver_after >= before + COALESCE_WINDOW


@pytest.mark.asyncio
async def test_edits_inside_the_window_merge_into_one_notification(
    client: AsyncClient,
) -> None:
    headers = await _headers(client)
    event = await _create_event(client, headers)

    patched = await client.patch(
        f"/v1/events/{event['id']}",
        json={"version": 1, "notes": "Debussy — new cast", "cover_image_url": "https://x/c.jpg"},
        headers=headers,
    )
    assert patched.status_code == 200, patched.text

    changes = await _notification_changes(client, headers)
    notifications = _latest(changes)
    assert len(notifications) == 1
    (payload,) = notifications.values()
    assert payload["kind"] == "event_created"
    assert payload["changes"] == ["program"]
    assert payload["version"] == 2
    assert [c["payload"]["version"] for c in changes] == [1, 2]


@pytest.mark.asyncio
async def test_unwatched_and_cosmetic_edits_stay_silent(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    headers = await _headers(client)
    event = await _create_event(client, headers)
    await _expire_pending(db_session)
    seen = len(await _notification_changes(client, headers))

    edits: list[dict[str, object]] = [
        {"cover_image_url": "https://x/new.jpg"},
        {"title": "Pelléas a Mélisanda"},
        {"departure_at": _iso(datetime.now(UTC) + timedelta(days=5))},
        {"notes": "  Debussy  "},
        {"venue_address": "Národní divadlo, Praha\n"},
    ]
    for version, edit in enumerate(edits, start=1):
        response = await client.patch(
            f"/v1/events/{event['id']}", json={"version": version, **edit}, headers=headers
        )
        assert response.status_code == 200, response.text

    assert len(await _notification_changes(client, headers)) == seen


@pytest.mark.asyncio
async def test_venue_change_after_the_window_is_a_new_notification(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    headers = await _headers(client)
    event = await _create_event(client, headers)
    await _expire_pending(db_session)

    response = await client.patch(
        f"/v1/events/{event['id']}",
        json={"version": 1, "venue_address": "Státní opera, Wilsonova 4, Praha"},
        headers=headers,
    )
    assert response.status_code == 200, response.text

    notifications = list(_latest(await _notification_changes(client, headers)).values())
    assert [n["kind"] for n in notifications] == ["event_created", "event_changed"]
    assert notifications[1]["changes"] == ["venue"]


@pytest.mark.asyncio
async def test_clearing_the_programme_counts_as_a_change(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    headers = await _headers(client)
    event = await _create_event(client, headers)
    await _expire_pending(db_session)

    response = await client.patch(
        f"/v1/events/{event['id']}", json={"version": 1, "notes": None}, headers=headers
    )
    assert response.status_code == 200, response.text

    notifications = list(_latest(await _notification_changes(client, headers)).values())
    assert notifications[-1]["kind"] == "event_changed"
    assert notifications[-1]["changes"] == ["program"]


@pytest.mark.asyncio
async def test_manual_notification_is_due_at_once(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    headers = await _headers(client)
    event = await _create_event(client, headers)
    await _expire_pending(db_session)

    response = await client.post(
        f"/v1/events/{event['id']}/notifications",
        json={"message": "  New cover photo from the premiere  "},
        headers=headers,
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["kind"] == "manual"
    assert body["message"] == "New cover photo from the premiere"
    assert datetime.fromisoformat(body["deliver_after"]) <= datetime.now(UTC)

    notifications = _latest(await _notification_changes(client, headers))
    assert notifications[body["id"]]["kind"] == "manual"


@pytest.mark.asyncio
async def test_manual_notification_merges_into_a_pending_change(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    headers = await _headers(client)
    event = await _create_event(client, headers)
    await _expire_pending(db_session)
    await client.patch(
        f"/v1/events/{event['id']}",
        json={"version": 1, "notes": "Changed cast"},
        headers=headers,
    )

    response = await client.post(
        f"/v1/events/{event['id']}/notifications",
        json={"message": "Check the new cast"},
        headers=headers,
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["kind"] == "manual"
    assert body["changes"] == ["program"]
    assert body["message"] == "Check the new cast"
    assert body["version"] == 2
    assert len(_latest(await _notification_changes(client, headers))) == 2


@pytest.mark.asyncio
async def test_manual_notification_without_message_and_for_a_missing_event(
    client: AsyncClient,
) -> None:
    headers = await _headers(client)
    event = await _create_event(client, headers)

    plain = await client.post(f"/v1/events/{event['id']}/notifications", json={}, headers=headers)
    assert plain.status_code == 201, plain.text
    assert plain.json()["message"] is None

    missing = await client.post(f"/v1/events/{uuid4()}/notifications", json={}, headers=headers)
    assert missing.status_code == 404

    too_long = await client.post(
        f"/v1/events/{event['id']}/notifications", json={"message": "x" * 501}, headers=headers
    )
    assert too_long.status_code == 422


@pytest.mark.asyncio
async def test_notification_through_the_outbox_is_idempotent(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    headers = await _headers(client, "bela@example.com")
    event = await _create_event(client, headers)
    await _expire_pending(db_session)
    op = {
        "op_id": str(uuid4()),
        "entity": "notification",
        "op": "create",
        "entity_id": event["id"],
        "payload": {"message": "Look at the new photo"},
    }

    first = (await client.post("/v1/sync/apply", json={"operations": [op]}, headers=headers)).json()
    retry = (await client.post("/v1/sync/apply", json={"operations": [op]}, headers=headers)).json()

    assert first["results"][0]["status"] == "applied"
    assert retry == first
    notifications = _latest(await _notification_changes(client, headers))
    assert len(notifications) == 2
    manual = notifications[first["results"][0]["entity_id"]]
    assert manual["kind"] == "manual"
    assert manual["message"] == "Look at the new photo"


@pytest.mark.asyncio
async def test_outbox_notification_for_a_deleted_event_is_not_found(
    client: AsyncClient,
) -> None:
    headers = await _headers(client)
    event = await _create_event(client, headers)
    await client.delete(f"/v1/events/{event['id']}", headers=headers)

    response = await client.post(
        "/v1/sync/apply",
        json={
            "operations": [
                {
                    "op_id": str(uuid4()),
                    "entity": "notification",
                    "op": "create",
                    "entity_id": event["id"],
                    "payload": {},
                }
            ]
        },
        headers=headers,
    )
    assert response.json()["results"][0]["status"] == "not_found"


@pytest.mark.asyncio
async def test_outbox_event_edits_announce_like_rest_edits(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    headers = await _headers(client)
    event = await _create_event(client, headers)
    await _expire_pending(db_session)

    response = await client.post(
        "/v1/sync/apply",
        json={
            "operations": [
                {
                    "op_id": str(uuid4()),
                    "entity": "event",
                    "op": "update",
                    "entity_id": event["id"],
                    "base_version": 1,
                    "payload": {"venue_address": "Rudolfinum", "notes": "Ravel"},
                }
            ]
        },
        headers=headers,
    )
    assert response.json()["results"][0]["status"] == "applied"

    notifications = list(_latest(await _notification_changes(client, headers)).values())
    assert notifications[-1]["kind"] == "event_changed"
    assert notifications[-1]["changes"] == ["program", "venue"]


@pytest.mark.asyncio
async def test_deleting_an_event_withdraws_its_pending_notification(
    client: AsyncClient,
) -> None:
    headers = await _headers(client)
    event = await _create_event(client, headers)

    await client.delete(f"/v1/events/{event['id']}", headers=headers)

    changes = await _notification_changes(client, headers)
    assert [c["op"] for c in changes] == ["upsert", "delete"]
    assert changes[-1]["payload"]["deleted_at"] is not None


@pytest.mark.asyncio
async def test_sync_page_carries_the_server_clock(client: AsyncClient) -> None:
    headers = await _headers(client)
    before = datetime.now(UTC)
    page = (await client.get("/v1/sync", headers=headers)).json()
    server_time = datetime.fromisoformat(page["server_time"])
    assert before - timedelta(seconds=5) <= server_time <= datetime.now(UTC) + timedelta(seconds=5)


async def _has_table(engine: AsyncEngine, name: str) -> bool:
    async with engine.connect() as conn:
        return await conn.run_sync(lambda sync: inspect(sync).has_table(name))


@pytest.mark.asyncio
async def test_migration_0019_downgrades_and_upgrades(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    headers = await _headers(client)
    await _create_event(client, headers)
    cfg = AlembicConfig(str(API_DIR / "alembic.ini"))
    cfg.set_main_option("script_location", str(API_DIR / "alembic"))
    cfg.set_main_option("prepend_sys_path", str(API_DIR / "src"))

    command.downgrade(cfg, "0018")
    assert not await _has_table(engine, "event_notifications")

    command.upgrade(cfg, "head")
    assert await _has_table(engine, "event_notifications")


@pytest.mark.asyncio
async def test_a_change_close_to_the_deadline_does_not_merge(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    # A merge this close to deliver_after could commit after a phone already
    # showed the notification; it becomes a notification of its own instead.
    headers = await _headers(client)
    event = await _create_event(client, headers)
    soon = await db_clock(db_session) + timedelta(seconds=5)
    await db_session.execute(update(EventNotification).values(deliver_after=soon))
    await db_session.commit()

    response = await client.patch(
        f"/v1/events/{event['id']}", json={"version": 1, "notes": "Changed"}, headers=headers
    )
    assert response.status_code == 200, response.text

    notifications = list(_latest(await _notification_changes(client, headers)).values())
    assert [(n["kind"], n["version"]) for n in notifications] == [
        ("event_created", 1),
        ("event_changed", 1),
    ]


@pytest.mark.asyncio
async def test_concurrent_announcements_make_one_notification(
    client: AsyncClient, engine: AsyncEngine, db_session: AsyncSession
) -> None:
    headers = await _headers(client)
    event = await _create_event(client, headers)
    await _expire_pending(db_session)
    factory = async_sessionmaker(bind=engine, expire_on_commit=False)

    async def announce_once(change: NotificationChange) -> None:
        async with factory() as session:
            row = await session.get(Event, UUID(event["id"]))
            assert row is not None
            await announce(session, row, row.created_by, NotificationKind.EVENT_CHANGED, [change])
            await asyncio.sleep(0.05)  # hold the lock while the other waits
            await session.commit()

    await asyncio.gather(
        announce_once(NotificationChange.VENUE), announce_once(NotificationChange.PROGRAM)
    )

    count = await db_session.scalar(
        select(func.count())
        .select_from(EventNotification)
        .where(EventNotification.kind == NotificationKind.EVENT_CHANGED)
    )
    assert count == 1
    notifications = list(_latest(await _notification_changes(client, headers)).values())
    assert notifications[-1]["changes"] == ["program", "venue"]


@pytest.mark.asyncio
async def test_announcing_a_deleted_event_raises(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    headers = await _headers(client)
    event = await _create_event(client, headers)
    row = await db_session.get(Event, UUID(event["id"]))
    assert row is not None
    await client.delete(f"/v1/events/{event['id']}", headers=headers)

    with pytest.raises(EventGone):
        await announce(db_session, row, row.created_by, NotificationKind.MANUAL)
    await db_session.rollback()


@pytest.mark.asyncio
async def test_an_unknown_entity_fails_alone_not_the_batch(client: AsyncClient) -> None:
    # An app newer than the API must not wedge its outbox: an entity or op
    # the server does not know is one `invalid` result, not a 422.
    headers = await _headers(client)
    event = await _create_event(client, headers)
    response = await client.post(
        "/v1/sync/apply",
        json={
            "operations": [
                {"op_id": str(uuid4()), "entity": "hologram", "op": "create", "payload": {}},
                {"op_id": str(uuid4()), "entity": "event", "op": "teleport"},
                {
                    "op_id": str(uuid4()),
                    "entity": "event",
                    "op": "update",
                    "entity_id": event["id"],
                    "base_version": 1,
                    "payload": {"title": "Still applied"},
                },
            ]
        },
        headers=headers,
    )
    assert response.status_code == 200, response.text
    assert [r["status"] for r in response.json()["results"]] == [
        "invalid",
        "invalid",
        "applied",
    ]
