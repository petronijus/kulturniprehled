#!/usr/bin/env python3
"""Count the pages of PDF files without third-party tools.

    python3 pdf_pages.py FILE.pdf [FILE.pdf ...]

Prints one ``<pages>\t<path>`` line per file. A box office often puts every
ticket of an order on its own page of one PDF, so the ingest skill compares
this count with the tickets it read: a page it skipped is a seat and a price
missing from the event.

The count is the page tree's ``/Count``, reached the way a reader reaches it:
the last ``/Root`` in the file (a classic trailer or a cross-reference stream
dictionary) names the catalog, the catalog names the page tree. Objects come
from the file body and from compressed object streams; a later definition of
an object number replaces an earlier one, as incremental updates intend.
Anything this cannot read (encryption, an unknown stream filter, a missing
object) is an error, never a guess.
"""

from __future__ import annotations

import re
import sys
import zlib
from pathlib import Path

_OBJ = re.compile(rb"(?<![0-9])(\d+)\s+(\d+)\s+obj\b(.*?)\bendobj", re.DOTALL)
_ROOT = re.compile(rb"/Root\s+(\d+)\s+\d+\s+R")
_STREAM = re.compile(rb"stream\r?\n")


def _int_entry(body: bytes, key: bytes) -> int | None:
    match = re.search(rb"/" + key + rb"(?![A-Za-z])\s+(\d+)(\s+\d+\s+R)?", body)
    if match is None:
        return None
    if match.group(2):
        raise ValueError(f"/{key.decode()} is an indirect reference")
    return int(match.group(1))


def _ref_entry(body: bytes, key: bytes) -> int | None:
    match = re.search(rb"/" + key + rb"(?![A-Za-z])\s+(\d+)\s+\d+\s+R", body)
    return int(match.group(1)) if match else None


def _dict_part(body: bytes) -> bytes:
    stream = _STREAM.search(body)
    return body[: stream.start()] if stream else body


def _object_stream(body: bytes) -> dict[int, bytes]:
    head = _dict_part(body)
    if b"/Encrypt" in head:
        raise ValueError("encrypted PDF")
    filters = re.findall(rb"/([A-Za-z0-9]+Decode)\b", head)
    if filters != [b"FlateDecode"]:
        names = ", ".join(f.decode() for f in filters) or "none"
        raise ValueError(f"object stream with unsupported filters: {names}")
    count = _int_entry(head, b"N")
    first = _int_entry(head, b"First")
    if count is None or first is None:
        raise ValueError("object stream without /N or /First")
    stream = _STREAM.search(body)
    if stream is None:
        raise ValueError("object stream without data")
    try:
        data = zlib.decompressobj().decompress(body[stream.end() :])
    except zlib.error as exc:
        raise ValueError(f"object stream does not inflate: {exc}") from exc
    numbers = [int(n) for n in data[:first].split()]
    if len(numbers) != 2 * count:
        raise ValueError("object stream header does not match /N")
    offsets = [*numbers[1::2], len(data) - first]
    return {numbers[2 * i]: data[first + offsets[i] : first + offsets[i + 1]] for i in range(count)}


def count_pages(pdf: bytes) -> int:
    """Pages in [pdf], read from its page tree; ValueError when unreadable."""
    if not pdf.startswith(b"%PDF-"):
        raise ValueError("not a PDF")
    objects: dict[int, bytes] = {}
    for match in _OBJ.finditer(pdf):
        number, body = int(match.group(1)), match.group(3)
        objects[number] = body
        if re.search(rb"/Type\s*/ObjStm\b", _dict_part(body)):
            objects.update(_object_stream(body))
    roots: list[bytes] = _ROOT.findall(pdf)
    if not roots:
        raise ValueError("no /Root: no trailer or cross-reference stream")
    catalog = objects.get(int(roots[-1]))
    if catalog is None:
        raise ValueError("the catalog object is missing")
    tree_number = _ref_entry(catalog, b"Pages")
    tree = objects.get(tree_number) if tree_number is not None else None
    if tree is None:
        raise ValueError("the page tree object is missing")
    count = _int_entry(tree, b"Count")
    if count is None:
        raise ValueError("the page tree has no /Count")
    return count


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    failed = False
    for name in argv:
        try:
            print(f"{count_pages(Path(name).read_bytes())}\t{name}")
        except (OSError, ValueError) as exc:
            print(f"ERROR\t{name}\t{exc}", file=sys.stderr)
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
