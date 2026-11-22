"""Ticket code decoding: the pure decoder and the scan that syncs its result."""

from __future__ import annotations

import base64
import io
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID

import httpx
import pytest
import zxingcpp
from httpx import AsyncClient
from PIL import Image
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from kp_api import ticket_scan
from kp_api.domain.ticket_codes import UnsupportedTicketType, decode_ticket_codes, to_pil
from kp_api.ticket_scan import scan_pending_tickets, scan_ticket
from tests.conftest import auth_header, login_as


def _code_image(content: str | bytes, fmt: zxingcpp.BarcodeFormat, scale: int = 4) -> Image.Image:
    return to_pil(zxingcpp.create_barcode(content, fmt).to_image(scale=scale))


def _page(*codes: tuple[Image.Image, tuple[int, int]]) -> Image.Image:
    page = Image.new("L", (1240, 1754), 255)
    for image, at in codes:
        page.paste(image, at)
    return page


def _pdf(*pages: Image.Image) -> bytes:
    buffer = io.BytesIO()
    pages[0].save(buffer, "PDF", resolution=150, save_all=True, append_images=list(pages[1:]))
    return buffer.getvalue()


def _png(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, "PNG")
    return buffer.getvalue()


def _ticket_pdf() -> bytes:
    return _pdf(
        _page(
            (_code_image("SEAT-12-ROW-4", zxingcpp.BarcodeFormat.QRCode), (100, 100)),
            (_code_image("AZTEC-RAIL", zxingcpp.BarcodeFormat.Aztec), (700, 110)),
            (_code_image("1234567890128", zxingcpp.BarcodeFormat.Code128, 3), (100, 900)),
        )
    )


def test_decodes_every_code_in_reading_order() -> None:
    codes = decode_ticket_codes(_ticket_pdf(), "application/pdf")

    assert [(c.format, c.text, c.page) for c in codes] == [
        ("qr", "SEAT-12-ROW-4", 0),
        ("aztec", "AZTEC-RAIL", 0),
        ("code128", "1234567890128", 0),
    ]
    assert codes[0].content_type == "text"


def _read_redraw(payload: dict[str, Any], fmt: zxingcpp.BarcodeFormat) -> list[zxingcpp.Barcode]:
    """What a scanner sees on the phone: the module bitmap scaled up with
    nearest-neighbour sampling inside a white quiet zone."""

    modules = Image.open(io.BytesIO(base64.b64decode(payload["modules_png_b64"]))).convert("L")
    assert modules.size == (payload["modules_width"], payload["modules_height"])
    scaled = modules.resize((modules.width * 6, modules.height * 6), Image.Resampling.NEAREST)
    screen = Image.new("L", (scaled.width + 120, scaled.height + 120), 255)
    screen.paste(scaled, (60, 60))
    return zxingcpp.read_barcodes(screen, formats=zxingcpp.BarcodeFormats(fmt))


@pytest.mark.parametrize(
    ("content", "fmt"),
    [
        ("SEAT-12-ROW-4", zxingcpp.BarcodeFormat.QRCode),
        (bytes(range(256)), zxingcpp.BarcodeFormat.Aztec),
        ("PDF417-TICKET-0001", zxingcpp.BarcodeFormat.PDF417),
        ("DM-TICKET-0001", zxingcpp.BarcodeFormat.DataMatrix),
        ("1234567890128", zxingcpp.BarcodeFormat.Code128),
        ("4006381333931", zxingcpp.BarcodeFormat.EAN13),
        ("ABC-123", zxingcpp.BarcodeFormat.Code39),
        ("12345678", zxingcpp.BarcodeFormat.ITF),
    ],
)
def test_redrawn_code_scans_to_the_printed_bytes(
    content: str | bytes, fmt: zxingcpp.BarcodeFormat
) -> None:
    printed = content.encode() if isinstance(content, str) else content
    page = _page((_code_image(content, fmt), (100, 100)))

    [code] = decode_ticket_codes(_pdf(page), "application/pdf")

    assert code.raw == printed
    [scanned] = _read_redraw(code.to_payload(), fmt)
    assert bytes(scanned.bytes) == printed


def test_gs1_code_is_redrawn_as_gs1() -> None:
    gs1 = zxingcpp.create_barcode("(01)09506000134352", zxingcpp.BarcodeFormat.Code128, gs1=True)
    image = to_pil(gs1.to_image(scale=3))

    [code] = decode_ticket_codes(_png(_page((image, (100, 100)))), "image/png")

    assert code.content_type == "gs1"
    [scanned] = _read_redraw(code.to_payload(), zxingcpp.BarcodeFormat.Code128)
    assert scanned.content_type == zxingcpp.ContentType.GS1
    assert scanned.text == "(01)09506000134352"


def test_one_code_per_page_and_a_repeated_code_once() -> None:
    first = _code_image("SEAT-1", zxingcpp.BarcodeFormat.QRCode)
    second = _code_image("SEAT-2", zxingcpp.BarcodeFormat.QRCode)
    pdf = _pdf(
        _page((first, (100, 100)), (first, (700, 1200))),
        _page((second, (100, 100))),
    )

    codes = decode_ticket_codes(pdf, "application/pdf")

    assert [(c.text, c.page) for c in codes] == [("SEAT-1", 0), ("SEAT-2", 1)]


def test_binary_payload_keeps_its_exact_bytes() -> None:
    payload = bytes(range(256))
    image = _page((_code_image(payload, zxingcpp.BarcodeFormat.Aztec), (100, 100)))

    [code] = decode_ticket_codes(_png(image), "image/png")

    assert code.raw == payload
    assert code.content_type == "binary"
    [scanned] = _read_redraw(code.to_payload(), zxingcpp.BarcodeFormat.Aztec)
    assert bytes(scanned.bytes) == payload


def test_page_without_codes_yields_nothing() -> None:
    assert decode_ticket_codes(_pdf(_page()), "application/pdf") == []


def test_calendar_ticket_is_unsupported() -> None:
    with pytest.raises(UnsupportedTicketType):
        decode_ticket_codes(b"BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n", "text/calendar")


def _future(days: int = 14) -> str:
    return (datetime.now(UTC) + timedelta(days=days)).isoformat().replace("+00:00", "Z")


async def _register_ticket(
    client: AsyncClient, headers: dict[str, str], content: bytes, mime_type: str
) -> dict[str, Any]:
    event = (
        await client.post(
            "/v1/events",
            json={"title": "Ticketed", "category": "concert", "starts_at": _future()},
            headers=headers,
        )
    ).json()
    upload = (
        await client.post(
            "/v1/tickets/upload-url",
            json={"event_id": event["id"], "mime_type": mime_type},
            headers=headers,
        )
    ).json()
    async with httpx.AsyncClient(timeout=10.0) as raw:
        put = await raw.put(upload["upload_url"], content=content)
    assert put.status_code in (200, 204), put.text
    register = await client.post(
        "/v1/tickets",
        json={
            "event_id": event["id"],
            "object_key": upload["object_key"],
            "mime_type": mime_type,
        },
        headers=headers,
    )
    assert register.status_code == 201, register.text
    body: dict[str, Any] = register.json()
    return body


async def _ticket_changes(client: AsyncClient, headers: dict[str, str]) -> list[dict[str, Any]]:
    page = (await client.get("/v1/sync", headers=headers)).json()
    return [c for c in page["changes"] if c["entity_type"] == "ticket"]


async def _listed(client: AsyncClient, headers: dict[str, str], ticket: dict[str, Any]) -> Any:
    listing = await client.get(f"/v1/events/{ticket['event_id']}/tickets", headers=headers)
    return listing.json()["items"][0]


@pytest.mark.asyncio
async def test_registered_ticket_gets_its_codes_synced(client: AsyncClient) -> None:
    headers = auth_header((await login_as(client, "petr@example.com"))["access_token"])

    ticket = await _register_ticket(client, headers, _ticket_pdf(), "application/pdf")

    assert ticket["codes"] is None
    listed = await _listed(client, headers, ticket)
    assert [c["text"] for c in listed["codes"]] == ["SEAT-12-ROW-4", "AZTEC-RAIL", "1234567890128"]
    assert listed["version"] == 2
    changes = await _ticket_changes(client, headers)
    assert [c["payload"]["version"] for c in changes] == [1, 2]
    assert changes[0]["payload"]["codes"] is None
    assert changes[1]["op"] == "upsert"
    first = changes[1]["payload"]["codes"][0]
    assert {k: first[k] for k in ("format", "text", "content_type", "page")} == {
        "format": "qr",
        "text": "SEAT-12-ROW-4",
        "content_type": "text",
        "page": 0,
    }
    assert first["modules_width"] == first["modules_height"] > 0
    assert [b.text for b in _read_redraw(first, zxingcpp.BarcodeFormat.QRCode)] == ["SEAT-12-ROW-4"]


@pytest.mark.asyncio
async def test_calendar_ticket_is_marked_scanned_with_no_codes(client: AsyncClient) -> None:
    headers = auth_header((await login_as(client, "petr@example.com"))["access_token"])

    ticket = await _register_ticket(client, headers, b"BEGIN:VCALENDAR\r\n", "text/calendar")

    assert (await _listed(client, headers, ticket))["codes"] == []


@pytest.mark.asyncio
async def test_unreadable_ticket_stays_unscanned_and_is_retried(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    headers = auth_header((await login_as(client, "petr@example.com"))["access_token"])

    ticket = await _register_ticket(client, headers, b"%PDF-1.4 truncated", "application/pdf")

    listed = await _listed(client, headers, ticket)
    assert listed["codes"] is None
    assert listed["version"] == 1
    assert [c["payload"]["version"] for c in await _ticket_changes(client, headers)] == [1]
    assert await scan_ticket(db_session, UUID(ticket["id"])) is False
    assert await scan_pending_tickets() == (0, 1)


@pytest.mark.asyncio
async def test_backfill_scans_tickets_left_unscanned(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    headers = auth_header((await login_as(client, "petr@example.com"))["access_token"])
    ticket = await _register_ticket(client, headers, _ticket_pdf(), "application/pdf")
    await db_session.execute(
        text("UPDATE tickets SET codes = NULL WHERE id = :id"),
        {"id": ticket["id"]},
    )
    await db_session.commit()

    assert await scan_pending_tickets() == (1, 0)
    assert len((await _listed(client, headers, ticket))["codes"]) == 3
    assert await scan_pending_tickets() == (0, 0)
    # Same codes on a rescan: nothing changed, so nothing is synced again.
    assert await scan_pending_tickets(rescan=True) == (1, 0)
    assert (await _listed(client, headers, ticket))["version"] == 3


@pytest.mark.asyncio
async def test_scan_never_resurrects_a_deleted_ticket(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    headers = auth_header((await login_as(client, "petr@example.com"))["access_token"])
    ticket = await _register_ticket(client, headers, _ticket_pdf(), "application/pdf")
    await client.delete(f"/v1/tickets/{ticket['id']}", headers=headers)

    assert await scan_ticket(db_session, UUID(ticket["id"]), rescan=True) is True

    changes = await _ticket_changes(client, headers)
    assert changes[-1]["op"] == "delete"


@pytest.mark.asyncio
async def test_ticket_deleted_while_decoding_is_not_resurrected(
    client: AsyncClient, db_session: AsyncSession, monkeypatch: pytest.MonkeyPatch
) -> None:
    headers = auth_header((await login_as(client, "petr@example.com"))["access_token"])
    ticket = await _register_ticket(client, headers, _ticket_pdf(), "application/pdf")
    version_before = (await _listed(client, headers, ticket))["version"]
    # Unscanned again, so the scan has something to write when it relocks.
    await db_session.execute(
        text("UPDATE tickets SET codes = NULL WHERE id = :id"), {"id": ticket["id"]}
    )
    await db_session.commit()
    real_decode = ticket_scan._decode

    async def decode_then_delete(object_key: str, mime_type: str) -> list[dict[str, object]]:
        codes = await real_decode(object_key, mime_type)
        deleted = await client.delete(f"/v1/tickets/{ticket['id']}", headers=headers)
        assert deleted.status_code == 204
        return codes

    monkeypatch.setattr(ticket_scan, "_decode", decode_then_delete)

    assert await scan_ticket(db_session, UUID(ticket["id"])) is True

    changes = await _ticket_changes(client, headers)
    assert changes[-1]["op"] == "delete"
    assert changes[-1]["payload"]["version"] == version_before + 1
    stored = await db_session.scalar(
        text("SELECT version FROM tickets WHERE id = :id"), {"id": ticket["id"]}
    )
    assert stored == version_before + 1
