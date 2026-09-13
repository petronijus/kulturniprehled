"""Slug-proof candidate identity — the unit half; the ingest half lives in
`test_season.py`."""

from __future__ import annotations

from datetime import UTC, datetime

from kp_api.domain.candidate_identity import candidate_identity, url_identity


def test_id_slug_survives_a_rewritten_tail() -> None:
    """The real 2026-09-12 ČF rewrite, both spellings of one concert."""

    before = url_identity(
        "https://www.ceskafilharmonie.cz/event/35524-simon-rattle-ceska-filharmonie/"
    )
    after = url_identity(
        "https://www.ceskafilharmonie.cz/event/35524-ceska-filharmonie-simon-rattle/"
    )
    assert before == after == "ceskafilharmonie.cz/event/35524"


def test_scheme_www_query_and_fragment_are_noise() -> None:
    assert (
        url_identity("HTTP://ceskafilharmonie.cz/event/35524-x?utm_source=fb#tickets")
        == url_identity("https://www.ceskafilharmonie.cz/event/35524-x/")
        == "ceskafilharmonie.cz/event/35524"
    )


def test_a_slug_only_url_has_no_identity_of_its_own() -> None:
    """Nothing stable to hold on to — the `dedup_key` is already the best we have."""

    assert url_identity("https://www.dvorakovapraha.cz/program/concertino-praga-2026") is None
    assert url_identity("https://www.prgphil.cz/liszt-faure-debussy") is None
    assert url_identity(None) is None
    assert url_identity("") is None


def test_a_bare_number_is_not_an_event_id() -> None:
    """`/archiv/2026` is a year listing; truncating it would merge a season."""

    assert url_identity("https://example.com/archiv/2026") is None


def test_different_events_of_one_venue_stay_apart() -> None:
    assert url_identity("https://ceskafilharmonie.cz/event/35524-a") != url_identity(
        "https://ceskafilharmonie.cz/event/35525-a"
    )


def test_identity_is_per_evening_not_per_production() -> None:
    """One URL, five nights — five candidates, exactly as `dedup_key` intends."""

    url = "https://ceskafilharmonie.cz/event/35524-x"
    first = candidate_identity(url, datetime(2026, 12, 16, 18, 30, tzinfo=UTC))
    second = candidate_identity(url, datetime(2026, 12, 17, 18, 30, tzinfo=UTC))
    assert first == "ceskafilharmonie.cz/event/35524|2026-12-16"
    assert first != second


def test_a_fixed_timezone_bug_does_not_change_the_evening() -> None:
    """17:30Z (the old hard-coded +02:00) and 18:30Z (real CET) are one concert."""

    url = "https://ceskafilharmonie.cz/event/35524-x"
    hard_coded_cest = candidate_identity(url, datetime(2026, 12, 16, 17, 30, tzinfo=UTC))
    real_cet = candidate_identity(url, datetime(2026, 12, 16, 18, 30, tzinfo=UTC))
    assert hard_coded_cest == real_cet


def test_the_date_is_prague_wall_time() -> None:
    """22:30Z on 15 Dec is already the 16th in Prague, and belongs to it."""

    url = "https://ceskafilharmonie.cz/event/35524-x"
    assert (
        candidate_identity(url, datetime(2026, 12, 15, 23, 30, tzinfo=UTC))
        == "ceskafilharmonie.cz/event/35524|2026-12-16"
    )


def test_an_event_id_in_the_query_identifies_the_evening() -> None:
    """palacakropolis.cz/work/33298?event_id=40543&no=62 — the path is the
    listing, the query is the concert, and `no` is the page the scrape walked."""

    assert (
        url_identity("http://www.palacakropolis.cz/work/33298?event_id=40543&no=62&page_id=33824")
        == "palacakropolis.cz/work/33298?event_id=40543"
    )
    assert url_identity("http://palacakropolis.cz/work/33298?event_id=40543&no=62") != url_identity(
        "http://palacakropolis.cz/work/33298?event_id=40662&no=71"
    )


def test_a_venue_answering_to_two_domains_has_one_identity() -> None:
    """The same Akropolis night, scraped off .com in August and .cz in September."""

    assert url_identity(
        "https://www.palacakropolis.com/work/33298?event_id=40543&no=48"
    ) == url_identity("http://www.palacakropolis.cz/work/33298?event_id=40543&no=62")


def test_a_listing_path_without_any_id_still_has_no_identity() -> None:
    """No id anywhere means no identity — merging a whole listing would be worse
    than leaving two rows for one evening."""

    assert url_identity("https://palacakropolis.cz/work/33298?no=62&page_id=33824") is None
