#!/usr/bin/env python3
"""Constraint canon for the Kulturní Přehled season planner.

This file is THE single source of truth for the plan rules. The season
orchestrator (`kulturni-sezona`) gates every scenario through `scenario`
before pushing; the weekly novelty watcher (`kulturni-prehled`) uses `fit`
to say where a fresh candidate would sit in the standing plan. The SPA's
`domain/violations.ts` mirrors these rules for live UI feedback — change
them here first, then mirror there.

Stdlib-only on purpose: it must run identically on the dev machines and in
the cloud routine's bare git checkout (no pip installs available there).

Subcommands
-----------
scenario --scenario s.json --pool pool.json [--context context.json]
         [--blocked blocked.json]
    Validate one scenario against the pool, booked events, history and
    blocked days. Prints {"ok", "violations", "warnings"}; exit 1 when any
    violation remains.

fit --candidate cand.json --plan plan.json [--context context.json]
    [--blocked blocked.json]
    Simulate inserting one candidate into the standing plan. Prints
    {"fits", "week", "fills_reserved_slot", "reasons_cs"}; exit 0 always
    (a non-fit is an answer, not an error).

Input shapes (all JSON):
  pool.json      [{dedup_key, lane, title, starts_at, program, price_czk,
                   season_event, ...}]
  s.json         {archetype, title_cs, events: [{dedup_key, why_cs?}],
                  reserved_slots: [{lane, month, note_cs}]}
  plan.json      {selected: [<candidate>], reserved_slots?: [...]}
  context.json   {booked: [{title, starts_at, category?}],
                  history_works_this_year: ["<composer>|<work>", ...],
                  history_works_last_year: [...]}
  blocked.json   {blocked_days: ["YYYY-MM-DD", ...],
                  conflicts: [{start_iso, end_iso, title}]}
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from datetime import datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

PRAGUE = ZoneInfo("Europe/Prague")

WEEK_CAP = 2
MIN_GAP_DAYS = 2
PRICE_EXCLUDE_CZK = 3000
PRICE_WARN_CZK = 2000
VIP_CLAMP_RATIO = 5
VIP_CLAMP_FACTOR = 4
MONTH_VARIETY_MIN_EVENTS = 3


def local_date(starts_at: str) -> str:
    moment = datetime.fromisoformat(starts_at.replace("Z", "+00:00"))
    return moment.astimezone(PRAGUE).date().isoformat()


def iso_week(date_str: str) -> str:
    year, week, _ = datetime.fromisoformat(date_str).isocalendar()
    return f"{year}-W{week:02d}"


def day_diff(a: str, b: str) -> int:
    return abs((datetime.fromisoformat(b).date() - datetime.fromisoformat(a).date()).days)


def normalize(value: str) -> str:
    stripped = unicodedata.normalize("NFD", value.lower())
    stripped = "".join(ch for ch in stripped if unicodedata.category(ch) != "Mn")
    stripped = re.sub(r"[^a-z0-9 ]", " ", stripped)
    return re.sub(r"\s+", " ", stripped).strip()


def work_keys(candidate: dict[str, Any]) -> list[str]:
    keys: list[str] = []
    for entry in candidate.get("program") or []:
        author = entry.get("composer") or entry.get("author") or entry.get("director")
        work = entry.get("work") or entry.get("play") or entry.get("film")
        if isinstance(author, str) and isinstance(work, str):
            keys.append(f"{normalize(author)}|{normalize(work)}")
    return keys


def parse_price(price_czk: str | None) -> tuple[int, int] | None:
    if not price_czk:
        return None
    numbers = [int(n.replace(" ", "").replace(" ", "")) for n in re.findall(r"\d[\d  ]*", price_czk)]
    if not numbers:
        return None
    return (min(numbers), max(numbers))


def price_midpoint(price_czk: str | None) -> int | None:
    """Effective midpoint with the VIP clamp from klasika preferences."""

    bounds = parse_price(price_czk)
    if bounds is None:
        return None
    lower, upper = bounds
    if lower > 0 and upper / lower > VIP_CLAMP_RATIO:
        upper = lower * VIP_CLAMP_FACTOR
    return (lower + upper) // 2


def load_json(path: str | None) -> Any:
    if path is None:
        return None
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


class Report:
    def __init__(self) -> None:
        self.violations: list[dict[str, Any]] = []
        self.warnings: list[dict[str, Any]] = []

    def violation(self, code: str, detail: str, **extra: Any) -> None:
        self.violations.append({"code": code, "detail": detail, **extra})

    def warning(self, code: str, detail: str, **extra: Any) -> None:
        self.warnings.append({"code": code, "detail": detail, **extra})


def timed_conflict(date_iso: str, starts_at: str, blocked: dict[str, Any] | None) -> str | None:
    """Return the conflicting calendar title, if any."""

    if blocked is None:
        return None
    if date_iso in set(blocked.get("blocked_days", [])):
        return f"blokovaný den {date_iso}"
    start = datetime.fromisoformat(starts_at.replace("Z", "+00:00"))
    for conflict in blocked.get("conflicts", []):
        try:
            c_start = datetime.fromisoformat(conflict["start_iso"])
            c_end = datetime.fromisoformat(conflict["end_iso"])
        except (KeyError, TypeError, ValueError):
            continue
        if c_start - timedelta(hours=2) <= start <= c_end + timedelta(hours=1):
            return str(conflict.get("title", "kalendářní událost"))
    return None


def check_schedule(
    report: Report,
    events: list[dict[str, Any]],
    booked: list[dict[str, Any]],
    blocked: dict[str, Any] | None,
) -> None:
    """Week cap + gap + blocked days over scenario/plan events and booked."""

    dated: list[tuple[str, dict[str, Any], bool]] = []
    for event in events:
        dated.append((local_date(event["starts_at"]), event, False))
    for event in booked:
        dated.append((local_date(event["starts_at"]), event, True))
    dated.sort(key=lambda item: item[0])

    by_week: dict[str, list[str]] = {}
    for date_iso, event, _ in dated:
        by_week.setdefault(iso_week(date_iso), []).append(str(event.get("title", "?")))
    for week, titles in sorted(by_week.items()):
        if len(titles) > WEEK_CAP:
            report.violation(
                "week_over",
                f"týden {week} má {len(titles)} akcí (limit {WEEK_CAP}): " + ", ".join(titles),
                week=week,
            )

    for (date_a, event_a, _), (date_b, event_b, _) in zip(dated, dated[1:]):
        gap = day_diff(date_a, date_b)
        if gap < MIN_GAP_DAYS and not (
            event_a.get("season_event") or event_b.get("season_event")
        ):
            report.violation(
                "gap",
                f"'{event_a.get('title')}' ({date_a}) a '{event_b.get('title')}' ({date_b}) "
                f"jsou {gap} den/dny od sebe (minimum {MIN_GAP_DAYS})",
            )

    for date_iso, event, is_booked in dated:
        if is_booked:
            continue
        conflict = timed_conflict(date_iso, event["starts_at"], blocked)
        if conflict is not None:
            report.violation(
                "blocked",
                f"'{event.get('title')}' ({date_iso}) koliduje: {conflict}",
                dedup_key=event.get("dedup_key"),
            )


def check_works(
    report: Report,
    events: list[dict[str, Any]],
    context: dict[str, Any] | None,
) -> None:
    this_year = {normalize(w.replace("|", " ")) for w in (context or {}).get("history_works_this_year", [])}
    last_year = {normalize(w.replace("|", " ")) for w in (context or {}).get("history_works_last_year", [])}

    seen: dict[str, str] = {}
    for event in events:
        for key in work_keys(event):
            flat = normalize(key.replace("|", " "))
            title = str(event.get("title", "?"))
            if key in seen:
                report.violation(
                    "duplicate_work",
                    f"dílo '{key.split('|')[1]}' je v plánu dvakrát: '{seen[key]}' a '{title}'",
                    work=key,
                )
            else:
                seen[key] = title
            if flat in this_year:
                report.violation(
                    "history_this_year",
                    f"'{title}': dílo '{key.split('|')[1]}' už Petr letos slyšel — hard veto",
                    work=key,
                )
            elif flat in last_year:
                report.warning(
                    "history_last_year",
                    f"'{title}': dílo '{key.split('|')[1]}' slyšel loni — doporučit jen pokud "
                    "výjimečné provedení",
                    work=key,
                )


def check_prices(report: Report, events: list[dict[str, Any]]) -> None:
    for event in events:
        midpoint = price_midpoint(event.get("price_czk"))
        if midpoint is None:
            continue
        title = str(event.get("title", "?"))
        if midpoint > PRICE_EXCLUDE_CZK:
            report.violation(
                "price_excluded",
                f"'{title}': efektivní střed ceny {midpoint} Kč přesahuje {PRICE_EXCLUDE_CZK} Kč",
                dedup_key=event.get("dedup_key"),
            )
        elif midpoint > PRICE_WARN_CZK:
            report.warning(
                "price_high",
                f"'{title}': efektivní střed ceny {midpoint} Kč (pásmo {PRICE_WARN_CZK}–{PRICE_EXCLUDE_CZK})",
            )


def check_month_variety(report: Report, events: list[dict[str, Any]]) -> None:
    by_month: dict[str, list[str]] = {}
    for event in events:
        by_month.setdefault(local_date(event["starts_at"])[:7], []).append(
            str(event.get("lane", "?"))
        )
    for month, lanes in sorted(by_month.items()):
        if len(lanes) >= MONTH_VARIETY_MIN_EVENTS and len(set(lanes)) == 1:
            report.warning(
                "month_monotone",
                f"měsíc {month}: {len(lanes)} akcí, všechny '{lanes[0]}' — zvaž pestřejší "
                "dramaturgii (éra/žánr řeší archetyp, tohle je čistě lane mix)",
                month=month,
            )


def check_lane_balance(report: Report, events: list[dict[str, Any]], pool: list[dict[str, Any]]) -> None:
    pool_lanes = {str(candidate.get("lane")) for candidate in pool}
    scenario_lanes = {str(event.get("lane")) for event in events}
    for lane in sorted(pool_lanes - scenario_lanes):
        report.warning(
            "lane_missing",
            f"lane '{lane}' má kandidáty v poolu, ale ve scénáři žádnou akci ani reserved slot",
            lane=lane,
        )


def resolve_events(
    scenario: dict[str, Any], pool: list[dict[str, Any]]
) -> tuple[list[dict[str, Any]], list[str]]:
    by_key = {candidate["dedup_key"]: candidate for candidate in pool}
    events: list[dict[str, Any]] = []
    missing: list[str] = []
    for member in scenario.get("events", []):
        key = member.get("dedup_key")
        candidate = by_key.get(key)
        if candidate is None:
            missing.append(str(key))
        else:
            events.append(candidate)
    return events, missing


def cmd_scenario(args: argparse.Namespace) -> int:
    scenario = load_json(args.scenario)
    pool = load_json(args.pool)
    context = load_json(args.context)
    blocked = load_json(args.blocked)

    report = Report()
    events, missing = resolve_events(scenario, pool)
    for key in missing:
        report.violation("unknown_key", f"scénář odkazuje na dedup_key mimo pool: {key}")

    booked = (context or {}).get("booked", [])
    check_schedule(report, events, booked, blocked)
    check_works(report, events, context)
    check_prices(report, events)
    check_month_variety(report, events)
    reserved_lanes = {slot.get("lane") for slot in scenario.get("reserved_slots", [])}
    scenario_with_slots = events + [
        {"lane": lane, "starts_at": "2000-01-01T00:00:00+00:00", "title": "reserved"}
        for lane in reserved_lanes
    ]
    check_lane_balance(report, scenario_with_slots, pool)

    ok = not report.violations
    json.dump(
        {"ok": ok, "violations": report.violations, "warnings": report.warnings},
        sys.stdout,
        ensure_ascii=False,
        indent=2,
    )
    print()
    return 0 if ok else 1


def cmd_fit(args: argparse.Namespace) -> int:
    candidate = load_json(args.candidate)
    plan = load_json(args.plan)
    context = load_json(args.context)
    blocked = load_json(args.blocked)

    selected = plan.get("selected", [])
    booked = (context or {}).get("booked", [])
    date_iso = local_date(candidate["starts_at"])
    week = iso_week(date_iso)
    reasons: list[str] = []
    fits = True

    # Simulate: run the schedule rules over plan + booked + the candidate.
    trial = Report()
    check_schedule(trial, [*selected, candidate], booked, blocked)
    check_works(trial, [*selected, candidate], context)

    # Only violations the candidate participates in count against the fit —
    # pre-existing plan violations are not the novelty's fault.
    baseline = Report()
    check_schedule(baseline, selected, booked, blocked)
    check_works(baseline, selected, context)
    baseline_set = {json.dumps(v, sort_keys=True, ensure_ascii=False) for v in baseline.violations}
    new_violations = [
        v
        for v in trial.violations
        if json.dumps(v, sort_keys=True, ensure_ascii=False) not in baseline_set
    ]
    if new_violations:
        fits = False
        reasons.extend(str(v["detail"]) for v in new_violations)
    else:
        reasons.append(f"týden {week} je volný, rozestupy sedí")

    fills_slot = None
    for slot in plan.get("reserved_slots", []):
        if slot.get("lane") == candidate.get("lane") and slot.get("month") == date_iso[:7]:
            fills_slot = slot
            reasons.append(
                f"zaplní rezervované místo: {slot.get('lane')}, {slot.get('month')}"
            )
            break

    json.dump(
        {
            "fits": fits,
            "week": week,
            "date": date_iso,
            "fills_reserved_slot": fills_slot,
            "reasons_cs": reasons,
        },
        sys.stdout,
        ensure_ascii=False,
        indent=2,
    )
    print()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    scenario_parser = subparsers.add_parser("scenario", help="validate one scenario")
    scenario_parser.add_argument("--scenario", required=True)
    scenario_parser.add_argument("--pool", required=True)
    scenario_parser.add_argument("--context")
    scenario_parser.add_argument("--blocked")
    scenario_parser.set_defaults(func=cmd_scenario)

    fit_parser = subparsers.add_parser("fit", help="check one candidate against the plan")
    fit_parser.add_argument("--candidate", required=True)
    fit_parser.add_argument("--plan", required=True)
    fit_parser.add_argument("--context")
    fit_parser.add_argument("--blocked")
    fit_parser.set_defaults(func=cmd_fit)

    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
