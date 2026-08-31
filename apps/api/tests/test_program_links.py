"""Programme media links: the folded piece identity and the upsert contract.

The fixtures in `test_folding_canon` are mirrored in the SPA's
`src/domain/programKey.test.ts` — the two normalizations must agree or the
planner looks up links that were stored under a different key.
"""

from __future__ import annotations

import pytest
from httpx import AsyncClient

from kp_api.domain.program_key import program_key
from tests.conftest import auth_header, login_as


async def _auth(client: AsyncClient) -> dict[str, str]:
    pair = await login_as(client, "petr@example.com")
    return auth_header(pair["access_token"])


def test_folding_canon() -> None:
    # Diacritics, case and punctuation all fold away.
    assert program_key("Antonín Dvořák", "Symfonie č. 9 e moll") == (
        "antonin dvorak|symfonie c 9 e moll"
    )
    assert program_key("ANTONIN  DVORAK", "  symfonie   c9 e-moll  ") == (
        "antonin dvorak|symfonie c9 e moll"
    )
    # A half-known piece still has an identity.
    assert program_key(None, "Requiem") == "|requiem"
    assert program_key("Arvo Pärt", None) == "arvo part|"


def test_folding_rejects_an_empty_piece() -> None:
    with pytest.raises(ValueError):
        program_key("  ", "…")


async def test_links_upsert_is_additive_per_service(client: AsyncClient) -> None:
    headers = await _auth(client)

    first = await client.put(
        "/v1/season/program-links",
        json={
            "items": [
                {
                    "author": "Antonín Dvořák",
                    "work": "Symfonie č. 9 e moll",
                    "spotify_url": "https://open.spotify.com/album/spotify-9",
                    "match_label": "Karajan / BPO",
                }
            ]
        },
        headers=headers,
    )
    assert first.status_code == 200, first.text
    assert first.json()["created"] == 1

    # A second pass resolving only YouTube must not drop the Spotify link,
    # and a differently-spelled title must land on the same row.
    second = await client.put(
        "/v1/season/program-links",
        json={
            "items": [
                {
                    "author": "ANTONIN DVORAK",
                    "work": "symfonie c. 9 e-moll",
                    "youtube_url": "https://youtu.be/yt-9",
                }
            ]
        },
        headers=headers,
    )
    assert second.status_code == 200, second.text
    assert second.json()["updated"] == 1

    listing = await client.get("/v1/season/program-links", headers=headers)
    assert listing.status_code == 200
    body = listing.json()
    assert body["total"] == 1
    item = body["items"][0]
    assert item["key"] == "antonin dvorak|symfonie c 9 e moll"
    assert item["spotify_url"] == "https://open.spotify.com/album/spotify-9"
    assert item["youtube_url"] == "https://youtu.be/yt-9"
    assert item["match_label"] == "Karajan / BPO"


async def test_track_uris_carry_the_movements_and_drop_junk(client: AsyncClient) -> None:
    """A work is its movements — order is kept, malformed URIs are dropped."""

    headers = await _auth(client)
    response = await client.put(
        "/v1/season/program-links",
        json={
            "items": [
                {
                    "author": "Gustav Mahler",
                    "work": "Symfonie č. 5",
                    "spotify_url": "https://open.spotify.com/album/mahler5",
                    "spotify_track_uris": [
                        "spotify:track:0000000000000000000001",
                        "https://open.spotify.com/track/nope",
                        "spotify:track:0000000000000000000002",
                    ],
                }
            ]
        },
        headers=headers,
    )
    assert response.status_code == 200, response.text

    listing = await client.get("/v1/season/program-links", headers=headers)
    item = listing.json()["items"][0]
    assert item["spotify_track_uris"] == [
        "spotify:track:0000000000000000000001",
        "spotify:track:0000000000000000000002",
    ]


async def test_repeated_identical_push_is_unchanged(client: AsyncClient) -> None:
    headers = await _auth(client)
    payload = {
        "items": [
            {
                "author": "Leoš Janáček",
                "work": "Taras Bulba",
                "spotify_url": "https://open.spotify.com/album/taras",
            }
        ]
    }

    await client.put("/v1/season/program-links", json=payload, headers=headers)
    again = await client.put("/v1/season/program-links", json=payload, headers=headers)

    assert again.json()["unchanged"] == 1
    assert again.json()["updated"] == 0


async def test_unusable_entries_are_skipped_not_fatal(client: AsyncClient) -> None:
    """One malformed row must not cost a resolver run over hundreds of pieces."""

    headers = await _auth(client)
    response = await client.put(
        "/v1/season/program-links",
        json={
            "items": [
                # No identity at all.
                {"author": " ", "work": "", "spotify_url": "https://open.spotify.com/album/x"},
                # Identity but nothing to play.
                {"author": "Bohuslav Martinů", "work": "Polní mše"},
                {
                    "author": "Bedřich Smetana",
                    "work": "Má vlast",
                    "spotify_url": "https://open.spotify.com/album/vlast",
                },
            ]
        },
        headers=headers,
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body == {"created": 1, "updated": 0, "unchanged": 0, "total": 1, "skipped": 2}


async def test_a_wrong_link_can_be_taken_back(client: AsyncClient) -> None:
    """The resolver guesses; there has to be an undo."""

    headers = await _auth(client)
    await client.put(
        "/v1/season/program-links",
        json={
            "items": [
                {
                    "author": "Bedřich Smetana",
                    "work": "písně",
                    "spotify_url": "https://open.spotify.com/album/wrong",
                }
            ]
        },
        headers=headers,
    )

    key = "bedrich smetana|pisne"
    deleted = await client.delete(f"/v1/season/program-links/{key}", headers=headers)
    assert deleted.status_code == 204

    listing = await client.get("/v1/season/program-links", headers=headers)
    assert listing.json()["total"] == 0

    # Deleting it twice is an error, not a silent success.
    again = await client.delete(f"/v1/season/program-links/{key}", headers=headers)
    assert again.status_code == 404
