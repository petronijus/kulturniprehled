import { describe, expect, it } from "vitest";
import {
  addDays,
  dayDiff,
  isoToLocalDate,
  isoWeek,
  monthGrid,
  monthsBetween,
  seasonWindowFor,
  weekday,
  weekStart,
} from "./season";

describe("isoWeek", () => {
  it("handles the year boundary (ISO year differs from calendar year)", () => {
    // 2026-12-28 is a Monday of ISO week 2026-W53; Jan 1–3 2027 belong to it.
    expect(isoWeek("2026-12-28")).toBe("2026-W53");
    expect(isoWeek("2027-01-01")).toBe("2026-W53");
    expect(isoWeek("2027-01-04")).toBe("2027-W01");
    // 2025-12-29 (Mon) already belongs to 2026-W01.
    expect(isoWeek("2025-12-29")).toBe("2026-W01");
    expect(isoWeek("2025-12-28")).toBe("2025-W52");
  });

  it("matches known mid-season weeks", () => {
    expect(isoWeek("2026-09-01")).toBe("2026-W36");
    expect(isoWeek("2026-10-14")).toBe("2026-W42");
  });
});

describe("day math", () => {
  it("computes calendar-day differences across DST transitions", () => {
    // CEST → CET switch on 2026-10-25 must not produce fractional days.
    expect(dayDiff("2026-10-24", "2026-10-26")).toBe(2);
    expect(dayDiff("2026-03-28", "2026-03-30")).toBe(2);
  });

  it("adds days across month and year seams", () => {
    expect(addDays("2026-12-30", 3)).toBe("2027-01-02");
    expect(addDays("2026-09-01", -1)).toBe("2026-08-31");
  });

  it("finds Mondays", () => {
    expect(weekStart("2026-09-06")).toBe("2026-08-31"); // Sunday → prev Monday
    expect(weekStart("2026-08-31")).toBe("2026-08-31");
    expect(weekday("2026-08-31")).toBe(1);
    expect(weekday("2026-09-06")).toBe(7);
  });
});

describe("isoToLocalDate", () => {
  it("converts UTC-normalized timestamps to Prague wall dates", () => {
    // 22:30 UTC in summer = 00:30 next day in Prague.
    expect(isoToLocalDate("2026-09-15T22:30:00Z")).toBe("2026-09-16");
    expect(isoToLocalDate("2026-09-15T17:30:00Z")).toBe("2026-09-15");
    // Winter: UTC+1.
    expect(isoToLocalDate("2026-12-01T23:30:00Z")).toBe("2026-12-02");
  });
});

describe("seasonWindowFor", () => {
  it("targets the upcoming season from July onward", () => {
    expect(seasonWindowFor("2026-08-09")).toEqual({
      label: "2026/27",
      startsOn: "2026-09-01",
      endsOn: "2027-06-30",
    });
    expect(seasonWindowFor("2026-07-01")).toEqual({
      label: "2026/27",
      startsOn: "2026-09-01",
      endsOn: "2027-06-30",
    });
  });

  it("stays in the running season before July", () => {
    expect(seasonWindowFor("2027-02-15")).toEqual({
      label: "2026/27",
      startsOn: "2026-09-01",
      endsOn: "2027-06-30",
    });
    expect(seasonWindowFor("2027-06-30").label).toBe("2026/27");
  });
});

describe("season months", () => {
  it("enumerates a Sep–Jun season as 10 months", () => {
    const months = monthsBetween("2026-09-01", "2027-06-30");
    expect(months).toHaveLength(10);
    expect(months[0]).toBe("2026-09");
    expect(months[9]).toBe("2027-06");
  });
});

describe("monthGrid", () => {
  it("covers the whole month in Mon–Sun rows", () => {
    const weeks = monthGrid("2026-09");
    const first = weeks[0];
    const last = weeks[weeks.length - 1];
    expect(first?.days[0]).toBe("2026-08-31");
    expect(last?.days.some((d) => d === "2026-09-30")).toBe(true);
    for (const week of weeks) {
      expect(week.days).toHaveLength(7);
      expect(weekday(week.start)).toBe(1);
    }
  });
});
