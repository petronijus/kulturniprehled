import { describe, expect, it } from "vitest";
import type { CalendarEntry, CalendarView } from "../api/types";
import { blockedDaysOf, dayTooltip, entriesByDay, entryLabel } from "./calendar";

function entry(overrides: Partial<CalendarEntry> = {}): CalendarEntry {
  return {
    uid: "e@kp",
    title: "Večeře u Karlových",
    day: "2026-10-20",
    all_day: false,
    starts_at: "2026-10-20T19:00:00+02:00",
    ends_at: "2026-10-20T22:00:00+02:00",
    blocking: false,
    span_days: 1,
    span_index: 0,
    ...overrides,
  };
}

function view(entries: CalendarEntry[], blocked: string[] = []): CalendarView {
  return {
    available: true,
    unavailable_reason: null,
    calendar_name: "Kocourek&Prdelčička",
    fetched_at: "2026-08-16T10:00:00+02:00",
    range_start: "2026-09-01",
    range_end: "2027-06-30",
    blocked_days: blocked,
    conflicts: [],
    entries,
  };
}

describe("blockedDaysOf", () => {
  it("is empty when the calendar is unavailable", () => {
    expect(blockedDaysOf(undefined).size).toBe(0);
  });

  it("takes the server-side classification verbatim", () => {
    const days = blockedDaysOf(view([], ["2026-10-12", "2026-10-13"]));
    expect(days.has("2026-10-12")).toBe(true);
    expect(days.has("2026-10-14")).toBe(false);
  });
});

describe("entriesByDay", () => {
  it("buckets a multi-day event into every day it covers", () => {
    const spread = view([
      entry({ uid: "trip@kp", day: "2026-10-12", span_days: 3, span_index: 0, all_day: true }),
      entry({ uid: "trip@kp", day: "2026-10-13", span_days: 3, span_index: 1, all_day: true }),
      entry({ uid: "dinner@kp", day: "2026-10-13" }),
    ]);
    const byDay = entriesByDay(spread);

    expect(byDay.get("2026-10-12")?.length).toBe(1);
    expect(byDay.get("2026-10-13")?.map((e) => e.uid)).toEqual(["trip@kp", "dinner@kp"]);
    expect(byDay.get("2026-10-14")).toBeUndefined();
  });
});

describe("entryLabel", () => {
  it("leads a timed entry with its start time", () => {
    expect(entryLabel(entry())).toBe("19:00 Večeře u Karlových");
  });

  it("counts the days of an all-day span", () => {
    const label = entryLabel(
      entry({
        title: "Chalupa",
        all_day: true,
        starts_at: null,
        ends_at: null,
        span_days: 3,
        span_index: 1,
      }),
    );
    expect(label).toBe("Chalupa 2/3");
  });

  it("shows where a continuation day ends", () => {
    const label = entryLabel(
      entry({
        title: "Party",
        day: "2026-11-02",
        starts_at: "2026-11-01T17:00:00+01:00",
        ends_at: "2026-11-02T01:00:00+01:00",
        span_days: 2,
        span_index: 1,
      }),
    );
    expect(label).toBe("do 01:00 Party");
  });
});

describe("dayTooltip", () => {
  it("lists every entry on its own line", () => {
    expect(
      dayTooltip([
        entry(),
        entry({ uid: "x", title: "Kino", starts_at: "2026-10-20T21:00:00+02:00" }),
      ]),
    ).toBe("19:00 Večeře u Karlových\n21:00 Kino");
  });
});
