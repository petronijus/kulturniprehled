"""Identity of a programme piece, shared by the API and the planner SPA.

A piece ("Antonín Dvořák" + "Symfonie č. 9 e moll") shows up in as many
programmes as there are concerts playing it, spelled slightly differently
every time — with or without diacritics, with the opus number attached, in
either case. Media links are resolved once per piece and reused across the
whole pool, so the pieces need one canonical identity.

**This normalization is mirrored in `apps/api/web/src/domain/programKey.ts`
and the two must agree**: the server keys the stored links, the SPA looks
them up from what the card is about to render. Both sides are tested
against the same fixtures — change one, change the other.
"""

from __future__ import annotations

import re
import unicodedata

_NON_ALNUM = re.compile(r"[^a-z0-9]+")


def _fold(text: str) -> str:
    """Lowercase, strip diacritics, collapse everything else to one space."""

    decomposed = unicodedata.normalize("NFKD", text.lower())
    stripped = "".join(char for char in decomposed if not unicodedata.combining(char))
    return _NON_ALNUM.sub(" ", stripped).strip()


def program_key(author: str | None, work: str | None) -> str:
    """`author|work`, both folded. Either half may be missing, never both.

    Raises `ValueError` on an entry that folds away to nothing — such a line
    is not a piece anyone can look up.
    """

    key = f"{_fold(author or '')}|{_fold(work or '')}"
    if key == "|":
        raise ValueError("programme entry has no printable author or work")
    return key
