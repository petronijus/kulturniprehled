"""Tests for pdf_pages.py. Run: python3 test_pdf_pages.py"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from pdf_pages import count_pages

HELPER = Path(__file__).resolve().parent / "pdf_pages.py"


def _page(number: int) -> bytes:
    page = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] >>"
    return f"{number} 0 obj\n{page}\nendobj\n".encode()


def _classic(pages: int) -> bytes:
    kids = " ".join(f"{3 + i} 0 R" for i in range(pages))
    return (
        b"%PDF-1.4\n"
        b"1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
        + f"2 0 obj\n<< /Type /Pages /Kids [{kids}] /Count {pages} >>\nendobj\n".encode()
        + b"".join(_page(3 + i) for i in range(pages))
        + b"trailer\n<< /Size 9 /Root 1 0 R >>\nstartxref\n0\n%%EOF\n"
    )


def _object_stream(objects: dict[int, bytes]) -> bytes:
    header = b""
    data = b""
    for number, body in objects.items():
        header += f"{number} {len(data)} ".encode()
        data += body + b"\n"
    packed = zlib.compress(header + data)
    return (
        f"10 0 obj\n<< /Type /ObjStm /N {len(objects)} /First {len(header)} "
        f"/Filter /FlateDecode /Length {len(packed)} >>\nstream\n".encode()
        + packed
        + b"\nendstream\nendobj\n"
    )


class CountPagesTest(unittest.TestCase):
    def test_two_tickets_in_one_file(self) -> None:
        # The 2026-10-31 opera: one PDF, a ticket per page, one seat recorded.
        self.assertEqual(count_pages(_classic(2)), 2)

    def test_single_page(self) -> None:
        self.assertEqual(count_pages(_classic(1)), 1)

    def test_an_incremental_update_wins(self) -> None:
        update = (
            b"2 0 obj\n<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>\nendobj\n"
            + _page(5)
            + b"trailer\n<< /Size 9 /Root 1 0 R /Prev 0 >>\nstartxref\n0\n%%EOF\n"
        )
        self.assertEqual(count_pages(_classic(2) + update), 3)

    def test_catalog_and_page_tree_in_an_object_stream(self) -> None:
        pdf = (
            b"%PDF-1.5\n"
            + _object_stream(
                {
                    1: b"<< /Type /Catalog /Pages 2 0 R >>",
                    2: b"<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
                    3: b"<< /Type /Page /Parent 2 0 R >>",
                    4: b"<< /Type /Page /Parent 2 0 R >>",
                }
            )
            + b"11 0 obj\n<< /Type /XRef /Size 12 /Root 1 0 R /W [1 2 1] /Length 0 >>\n"
            + b"stream\n\nendstream\nendobj\nstartxref\n0\n%%EOF\n"
        )
        self.assertEqual(count_pages(pdf), 2)

    def test_refuses_what_it_cannot_read(self) -> None:
        cases = {
            "not a PDF": b"<html>ticket</html>",
            "no root": _classic(2).replace(b"/Root 1 0 R", b""),
            "indirect count": _classic(2).replace(b"/Count 2", b"/Count 9 0 R"),
            "unknown filter": b"%PDF-1.5\n"
            + _object_stream({1: b"<< >>"}).replace(b"/FlateDecode", b"/LZWDecode"),
        }
        for name, pdf in cases.items():
            with self.subTest(name), self.assertRaises(ValueError):
                count_pages(pdf)


class CliTest(unittest.TestCase):
    def test_prints_counts_and_fails_loudly_on_a_bad_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            good = Path(tmp) / "tickets.pdf"
            good.write_bytes(_classic(2))
            bad = Path(tmp) / "broken.pdf"
            bad.write_bytes(b"not a pdf")
            run = subprocess.run(
                [sys.executable, str(HELPER), str(good), str(bad)],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(run.returncode, 1)
        self.assertEqual(run.stdout, f"2\t{good}\n")
        self.assertIn(f"ERROR\t{bad}", run.stderr)


if __name__ == "__main__":
    unittest.main()
