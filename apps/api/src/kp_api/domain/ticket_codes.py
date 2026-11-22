"""Find the scannable codes (QR, Aztec, PDF417, barcodes, …) inside a ticket.

Each code is re-encoded with the same library that decoded it and stored as
a module bitmap (one pixel per module, no quiet zone), which the phones only
scale up — no symbology logic on the phone, so nothing there can redraw a
code wrongly. A redrawn code is kept only after it reads back to exactly
the bytes printed on the ticket. Decoding is CPU-bound and synchronous;
callers run it off the event loop.
"""

from __future__ import annotations

import base64
import io
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from typing import Any

import pypdfium2 as pdfium
import zxingcpp
from PIL import Image, UnidentifiedImageError

# Rendering at ~300 dpi keeps the narrow bars of a printed Code128 apart;
# the pixel cap keeps a poster-sized page from eating the container's memory.
_PDF_SCALE = 300 / 72
_MAX_RENDER_PX = 5000
_MAX_PDF_PAGES = 20

# Stable identifiers shared with the mobile renderer. zxing-cpp's own enum
# names have changed between major versions (Aztec → AztecCode), so the
# synced payload never carries them.
_FORMATS: dict[str, str] = {
    "QRCode": "qr",
    "QRCodeModel1": "qr",
    "QRCodeModel2": "qr",
    "MicroQRCode": "micro_qr",
    "RMQRCode": "rmqr",
    "Aztec": "aztec",
    "AztecCode": "aztec",
    "PDF417": "pdf417",
    "CompactPDF417": "pdf417",
    "MicroPDF417": "micro_pdf417",
    "DataMatrix": "data_matrix",
    "Code128": "code128",
    "Code39": "code39",
    "Code39Std": "code39",
    "Code39Ext": "code39",
    "Code93": "code93",
    "EAN13": "ean13",
    "EAN8": "ean8",
    "UPCA": "upca",
    "UPCE": "upce",
    "ITF": "itf",
    "ITF14": "itf",
    "Codabar": "codabar",
}

_CONTENT_TYPES: dict[str, str] = {
    "Text": "text",
    "Binary": "binary",
    "Mixed": "binary",
    "GS1": "gs1",
    "ISO15434": "text",
    "UnknownECI": "binary",
}


class UnsupportedTicketType(ValueError):
    """The ticket blob is neither a PDF nor a raster image."""


class UnreadableTicket(ValueError):
    """The blob claims to be a PDF or an image but cannot be opened —
    retrying will not change that."""


@dataclass(frozen=True)
class TicketCode:
    format: str
    text: str
    raw: bytes
    content_type: str
    page: int
    # 1-bit PNG, one pixel per module; None when the code could not be
    # redrawn faithfully (the phone then leaves it to the PDF).
    modules_png: bytes | None
    modules_width: int
    modules_height: int

    def to_payload(self) -> dict[str, Any]:
        return {
            "format": self.format,
            "text": self.text,
            "content_type": self.content_type,
            "page": self.page,
            "modules_png_b64": (
                base64.b64encode(self.modules_png).decode("ascii")
                if self.modules_png is not None
                else None
            ),
            "modules_width": self.modules_width,
            "modules_height": self.modules_height,
        }


def _format_id(fmt: zxingcpp.BarcodeFormat) -> str:
    name = fmt.name or str(fmt)
    return _FORMATS.get(name, f"other:{name}")


def _content_type_id(content_type: zxingcpp.ContentType) -> str:
    return _CONTENT_TYPES.get(content_type.name or "", "binary")


def _reading_order(row_height: int) -> Callable[[zxingcpp.Barcode], tuple[int, int]]:
    """Rows of a twentieth of the page, left to right inside a row, so two
    codes printed side by side keep their left-to-right order even when
    their top edges differ by a few pixels."""

    def key(barcode: zxingcpp.Barcode) -> tuple[int, int]:
        position = barcode.position
        top = min(position.top_left.y, position.top_right.y)
        left = min(position.top_left.x, position.bottom_left.x)
        return top // row_height, left

    return key


def to_pil(image: zxingcpp.Image) -> Image.Image:
    view = memoryview(image)
    shape = view.shape
    if shape is None or len(shape) != 2:
        raise ValueError(f"unexpected zxing image shape {shape}")
    return Image.frombuffer("L", (shape[1], shape[0]), bytes(view))


def _candidates(found: zxingcpp.Barcode) -> list[tuple[str | bytes, dict[str, bool]]]:
    """Ways to feed the decoded content back to the encoder, most faithful
    first: GS1 needs its human-readable form with the GS1 flag, everything
    else its raw bytes, with the text as a fallback for linear symbologies
    whose encoder only takes characters."""

    raw = bytes(found.bytes)
    if found.content_type == zxingcpp.ContentType.GS1:
        return [(found.text, {"gs1": True}), (raw, {})]
    return [(raw, {}), (found.text, {})]


def _reads_back(redrawn: zxingcpp.Barcode, found: zxingcpp.Barcode) -> bool:
    image = to_pil(redrawn.to_image(scale=4))
    return any(
        bytes(r.bytes) == bytes(found.bytes) and r.content_type == found.content_type
        for r in zxingcpp.read_barcodes(image, formats=zxingcpp.BarcodeFormats(found.format))
    )


def _redraw(found: zxingcpp.Barcode) -> Image.Image | None:
    for content, options in _candidates(found):
        try:
            redrawn = zxingcpp.create_barcode(content, found.format, **options)
        except ValueError:
            continue  # the encoder refuses this form of the content; try the next
        if _reads_back(redrawn, found):
            return to_pil(redrawn.to_image(scale=1, add_quiet_zones=False))
    return None


def _png(modules: Image.Image) -> bytes:
    buffer = io.BytesIO()
    modules.convert("1", dither=Image.Dither.NONE).save(buffer, "PNG", optimize=True)
    return buffer.getvalue()


def _decode_image(image: Image.Image, page: int) -> list[TicketCode]:
    found = sorted(
        (b for b in zxingcpp.read_barcodes(image.convert("L")) if b.valid),
        key=_reading_order(max(image.height // 20, 1)),
    )
    codes: list[TicketCode] = []
    for barcode in found:
        modules = _redraw(barcode)
        codes.append(
            TicketCode(
                format=_format_id(barcode.format),
                text=barcode.text,
                raw=bytes(barcode.bytes),
                content_type=_content_type_id(barcode.content_type),
                page=page,
                modules_png=_png(modules) if modules is not None else None,
                modules_width=modules.width if modules is not None else 0,
                modules_height=modules.height if modules is not None else 0,
            )
        )
    return codes


def _pdf_pages(data: bytes) -> Iterator[Image.Image]:
    """One rendered page at a time, so a long PDF never holds more than one
    page bitmap in the API's memory."""

    pdf = pdfium.PdfDocument(data)
    try:
        for index in range(min(len(pdf), _MAX_PDF_PAGES)):
            page = pdf[index]
            try:
                width, height = page.get_size()
                scale = min(_PDF_SCALE, _MAX_RENDER_PX / max(width, height, 1))
                yield page.render(scale=scale, grayscale=True).to_pil()
            finally:
                page.close()
    finally:
        pdf.close()


def _raster_pages(data: bytes) -> Iterator[Image.Image]:
    with Image.open(io.BytesIO(data)) as image:
        if max(image.size) > _MAX_RENDER_PX:
            # draft() lets JPEG decode at a reduced size instead of
            # materialising a huge photo first.
            image.draft("L", (_MAX_RENDER_PX, _MAX_RENDER_PX))
        image.load()
        page = image.convert("L")
    if max(page.size) > _MAX_RENDER_PX:
        page.thumbnail((_MAX_RENDER_PX, _MAX_RENDER_PX))
    yield page


def decode_ticket_codes(data: bytes, mime_type: str) -> list[TicketCode]:
    """Every distinct code in the ticket, page by page, top to bottom.

    A code printed twice (stub and main ticket) is returned once. Raises
    `UnsupportedTicketType` for an ICS or any other non-visual blob and
    `UnreadableTicket` for a corrupt PDF or image.
    """

    pages: Iterator[Image.Image]
    if mime_type == "application/pdf" or data.startswith(b"%PDF"):
        pages = _pdf_pages(data)
    elif mime_type.startswith("image/"):
        pages = _raster_pages(data)
    else:
        raise UnsupportedTicketType(mime_type)

    seen: set[tuple[str, bytes]] = set()
    codes: list[TicketCode] = []
    try:
        for index, image in enumerate(pages):
            for code in _decode_image(image, index):
                key = (code.format, code.raw)
                if key in seen:
                    continue
                seen.add(key)
                codes.append(code)
    except (pdfium.PdfiumError, UnidentifiedImageError) as exc:
        raise UnreadableTicket(str(exc)) from exc
    return codes
