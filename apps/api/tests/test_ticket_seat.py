"""Seat labels read from ticket page text, and their place in the decoder."""

from __future__ import annotations

import zlib

import pytest
import zxingcpp

from kp_api.domain.ticket_codes import decode_ticket_codes, to_pil
from kp_api.domain.ticket_seat import seat_label

# Page texts in the layouts of the ticket sellers seen so far (as PDFium
# extracts them), with made-up events.
RUDOLFINUM = "\r\n".join(
    [
        "Koncert",
        "22.11.2099",
        "I. kategorie, 1690 Kč",
        "Přízemí vpravo",
        "Řada 10, Místo 19",
        "Rudolfinum",
    ]
)
SECTOR_FIELD = "\r\n".join(
    [
        "Koncert",
        "Datum a místo konání: 09.11.2099 19:30",
        "Sektor: Přízemí vpravo",
        "Řada: 5",
        "Místo: 19",
        "Cena: 1200 Kč",
    ]
)
CAPITALS = "\r\n".join(
    [
        "Číslo vstupenky:",
        "30562022271",
        "SÁL Dvořákova síň",
        "PODLAŽÍ Přízemí",
        "STRANA vpravo",
        "ŘADA 16",
        "SEDADLO 27",
        "CENA 950 Kč",
    ]
)
BILINGUAL = "\r\n".join(
    [
        "Rudolfinum",
        "Řada|Row: 5",
        "Sedadlo|Seat: 6",
        "Umístění|Location:Přízemí",
        "Strana|Side: vlevo",
        "Sektor|Sector:",
        "Cena|Price:900 Kč",
    ]
)
BILINGUAL_SIDE_REPEATED = "\r\n".join(
    [
        "Obecní dům",
        "Řada|Row: 2",
        "Sedadlo|Seat: 5",
        "Umístění|Location: Přízemí vpravo",
        "Strana|Side: vpravo",
    ]
)
UNLABELLED = "\r\n".join(
    [
        "Národní divadlo",
        "31.10.2099, 19:00",
        "Opera",
        "Přízemí vlevo 6 11",
        "1490 Kč",
    ]
)
NO_SEAT = "\r\n".join(
    [
        "Koncert",
        "Fri\xa04/12/2099\xa019:30 ",
        "Divadlo X10 ",
        "Charvátova 39/10, Praha 1",
    ]
)
TWO_SEATS = "\r\n".join(
    [
        "Koncert",
        "Řada 1, Místo 2",
        "Řada 1, Místo 3",
    ]
)
NO_DIACRITICS = "\r\n".join(
    [
        "Koncert",
        "Prizemi vpravo",
        "Rada 10, Misto 19",
    ]
)


@pytest.mark.parametrize(
    ("text", "label"),
    [
        (RUDOLFINUM, "Přízemí vpravo · Řada 10 · Místo 19"),
        (SECTOR_FIELD, "Přízemí vpravo · Řada 5 · Místo 19"),
        (CAPITALS, "Přízemí vpravo · Řada 16 · Sedadlo 27"),
        (BILINGUAL, "Přízemí vlevo · Řada 5 · Sedadlo 6"),
        (BILINGUAL_SIDE_REPEATED, "Přízemí vpravo · Řada 2 · Sedadlo 5"),
        (NO_DIACRITICS, "Prizemi vpravo · Rada 10 · Misto 19"),
    ],
)
def test_reads_the_seat_in_every_known_layout(text: str, label: str) -> None:
    assert seat_label(text) == label


@pytest.mark.parametrize("text", [UNLABELLED, NO_SEAT, TWO_SEATS, ""])
def test_no_label_rather_than_a_guess(text: str) -> None:
    assert seat_label(text) is None


def test_the_place_of_the_concert_is_not_a_seat() -> None:
    text = "Datum a místo konání: 09.11.2099 19:30\r\nŘada: 5\r\nCena: 100 Kč"

    assert seat_label(text) is None


def _text_pdf(pages: list[tuple[list[str], bytes]]) -> bytes:
    """A minimal PDF whose pages carry real text lines (Helvetica, ASCII)
    and a QR image — what a seller's e-ticket looks like to PDFium."""

    objects: list[bytes] = []

    def add(body: bytes) -> int:
        objects.append(body)
        return len(objects)

    font = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    page_ids: list[int] = []
    page_refs: list[tuple[int, int]] = []
    for lines, code_text in pages:
        image = to_pil(
            zxingcpp.create_barcode(code_text, zxingcpp.BarcodeFormat.QRCode).to_image(scale=8)
        )
        raw = zlib.compress(image.tobytes())
        image_id = add(
            b"<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceGray"
            b" /BitsPerComponent 8 /Filter /FlateDecode /Length %d >>\nstream\n%s\nendstream"
            % (image.width, image.height, len(raw), raw)
        )
        text_ops = b"BT /F1 14 Tf 50 780 Td 16 TL " + b" ".join(
            b"(%s) Tj T*" % line.encode("ascii") for line in lines
        )
        content = text_ops + b" ET q 240 0 0 240 150 300 cm /Im1 Do Q"
        content_id = add(b"<< /Length %d >>\nstream\n%s\nendstream" % (len(content), content))
        page_refs.append((image_id, content_id))
    pages_id = len(objects) + len(page_refs) + 1
    # The page tree follows the pages, so its id is known before they are added.
    for image_id, content_id in page_refs:
        page_ids.append(
            add(
                b"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 595 842] /Contents %d 0 R"
                b" /Resources << /Font << /F1 %d 0 R >> /XObject << /Im1 %d 0 R >> >> >>"
                % (pages_id, content_id, font, image_id)
            )
        )
    kids = b" ".join(b"%d 0 R" % i for i in page_ids)
    assert add(b"<< /Type /Pages /Kids [%s] /Count %d >>" % (kids, len(page_ids))) == pages_id
    catalog = add(b"<< /Type /Catalog /Pages %d 0 R >>" % pages_id)

    out = bytearray(b"%PDF-1.4\n")
    offsets: list[int] = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n%s\nendobj\n" % (number, body)
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    out += b"".join(b"%010d 00000 n \n" % offset for offset in offsets)
    out += b"trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (
        len(objects) + 1,
        catalog,
        xref,
    )
    return bytes(out)


def test_each_code_carries_the_seat_of_its_own_page() -> None:
    pdf = _text_pdf(
        [
            (["Koncert", "Prizemi vpravo", "Rada 10, Misto 19"], b"TICKET-19"),
            (["Koncert", "Prizemi vpravo", "Rada 10, Misto 20"], b"TICKET-20"),
            (["Koncert", "Volne sezeni"], b"TICKET-21"),
        ]
    )

    codes = decode_ticket_codes(pdf, "application/pdf")

    assert [(c.text, c.page, c.seat) for c in codes] == [
        ("TICKET-19", 0, "Prizemi vpravo · Rada 10 · Misto 19"),
        ("TICKET-20", 1, "Prizemi vpravo · Rada 10 · Misto 20"),
        ("TICKET-21", 2, None),
    ]
    assert codes[0].to_payload()["seat"] == "Prizemi vpravo · Rada 10 · Misto 19"
