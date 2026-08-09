import { describe, expect, it } from "vitest";
import type { PlannedItem } from "./violations";
import { computeViolations, workKey } from "./violations";

function item(overrides: Partial<PlannedItem> & { id: string; date: string }): PlannedItem {
  return {
    title: overrides.id,
    seasonEvent: false,
    workKeys: [],
    booked: false,
    ...overrides,
  };
}

const noBlocked = new Set<string>();

describe("week cap", () => {
  it("flags a third event in one ISO week, counting booked events", () => {
    const violations = computeViolations(
      [
        item({ id: "a", date: "2026-10-12" }),
        item({ id: "b", date: "2026-10-15", booked: true }),
        item({ id: "c", date: "2026-10-17" }),
      ],
      noBlocked,
    );
    const week = violations.find((v) => v.kind === "week_over");
    expect(week).toMatchObject({ week: "2026-W42", count: 3 });
  });

  it("season_event never exempts the cap", () => {
    const violations = computeViolations(
      [
        item({ id: "a", date: "2026-10-12" }),
        item({ id: "b", date: "2026-10-14" }),
        item({ id: "c", date: "2026-10-16", seasonEvent: true }),
      ],
      noBlocked,
    );
    expect(violations.some((v) => v.kind === "week_over")).toBe(true);
  });

  it("counts the ISO week across the year boundary", () => {
    const violations = computeViolations(
      [
        item({ id: "a", date: "2026-12-29" }),
        item({ id: "b", date: "2026-12-31" }),
        item({ id: "c", date: "2027-01-02" }),
      ],
      noBlocked,
    );
    const week = violations.find((v) => v.kind === "week_over");
    expect(week).toMatchObject({ week: "2026-W53", count: 3 });
  });
});

describe("gap rule", () => {
  it("flags back-to-back events", () => {
    const violations = computeViolations(
      [item({ id: "a", date: "2026-10-12" }), item({ id: "b", date: "2026-10-13" })],
      noBlocked,
    );
    expect(violations.find((v) => v.kind === "gap")).toMatchObject({ aId: "a", bId: "b", days: 1 });
  });

  it("allows exactly two days apart", () => {
    const violations = computeViolations(
      [item({ id: "a", date: "2026-10-13" }), item({ id: "b", date: "2026-10-15" })],
      noBlocked,
    );
    expect(violations.some((v) => v.kind === "gap")).toBe(false);
  });

  it("season_event exempts the gap on either side", () => {
    const violations = computeViolations(
      [
        item({ id: "a", date: "2026-10-12" }),
        item({ id: "b", date: "2026-10-13", seasonEvent: true }),
      ],
      noBlocked,
    );
    expect(violations.some((v) => v.kind === "gap")).toBe(false);
  });

  it("counts a gap against booked events too", () => {
    const violations = computeViolations(
      [item({ id: "a", date: "2026-10-12", booked: true }), item({ id: "b", date: "2026-10-13" })],
      noBlocked,
    );
    expect(violations.some((v) => v.kind === "gap")).toBe(true);
  });
});

describe("duplicate works", () => {
  it("normalizes diacritics and case before comparing", () => {
    expect(workKey("Gustav Mahler", "Symfonie č. 5")).toBe(
      workKey("gustav mahler", "SYMFONIE C 5"),
    );
  });

  it("flags the same work planned twice", () => {
    const key = workKey("Mahler", "Symfonie 5");
    const violations = computeViolations(
      [
        item({ id: "a", date: "2026-10-12", workKeys: [key] }),
        item({ id: "b", date: "2026-11-20", workKeys: [key] }),
      ],
      noBlocked,
    );
    expect(violations.find((v) => v.kind === "duplicate_work")).toMatchObject({
      itemIds: ["a", "b"],
    });
  });
});

describe("blocked days", () => {
  it("flags planned events on blocked days but exempts booked ones", () => {
    const blocked = new Set(["2026-10-12"]);
    const violations = computeViolations(
      [item({ id: "a", date: "2026-10-12" }), item({ id: "b", date: "2026-10-12", booked: true })],
      blocked,
    );
    const hits = violations.filter((v) => v.kind === "blocked_day");
    expect(hits).toHaveLength(1);
    expect(hits[0]).toMatchObject({ itemId: "a" });
  });
});

describe("clean plan", () => {
  it("returns no violations for a well-spaced plan", () => {
    const violations = computeViolations(
      [
        item({ id: "a", date: "2026-09-10" }),
        item({ id: "b", date: "2026-09-22" }),
        item({ id: "c", date: "2026-10-06" }),
      ],
      noBlocked,
    );
    expect(violations).toEqual([]);
  });
});
