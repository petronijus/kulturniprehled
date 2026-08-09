/** The constraint engine — a pure function over the plan.
 *
 * Rules (mirrors skills/kulturni-sezona/bin/kp_validate.py, the canon):
 *  - ≤2 events per ISO week, counting booked KP events; `season_event`
 *    never exempts the cap.
 *  - ≥2 calendar days between any two events; `season_event: true` exempts
 *    the gap rule only (either side being a season event waives the pair).
 *  - The same musical work must not appear twice in one season.
 *  - Events must not land on blocked days.
 *
 * Violations are advisory — the UI surfaces them, Petr overrules them.
 */

import type { IsoDate } from "./season";
import { dayDiff, isoWeek } from "./season";

export interface PlannedItem {
  id: string;
  title: string;
  date: IsoDate;
  seasonEvent: boolean;
  /** Normalized work keys from the program (composer|work). */
  workKeys: string[];
  /** Booked KP events participate in week/gap rules but are immutable. */
  booked: boolean;
}

export type Violation =
  | { kind: "week_over"; week: string; count: number; itemIds: string[] }
  | { kind: "gap"; aId: string; bId: string; aTitle: string; bTitle: string; days: number }
  | { kind: "duplicate_work"; work: string; itemIds: string[] }
  | { kind: "blocked_day"; itemId: string; title: string; day: IsoDate };

const WEEK_CAP = 2;
const MIN_GAP_DAYS = 2;

/** Normalize a program entry into a comparable work key. */
export function workKey(composer: string, work: string): string {
  const normalize = (value: string) =>
    value
      .toLowerCase()
      .normalize("NFD")
      .replace(/[̀-ͯ]/g, "")
      .replace(/[^a-z0-9 ]/g, " ")
      .replace(/\s+/g, " ")
      .trim();
  return `${normalize(composer)}|${normalize(work)}`;
}

export function computeViolations(
  items: readonly PlannedItem[],
  blockedDays: ReadonlySet<IsoDate>,
): Violation[] {
  const violations: Violation[] = [];
  const sorted = [...items].sort((a, b) => a.date.localeCompare(b.date));

  // Week cap — booked events count, season_event does not exempt.
  const byWeek = new Map<string, PlannedItem[]>();
  for (const item of sorted) {
    const week = isoWeek(item.date);
    const bucket = byWeek.get(week);
    if (bucket === undefined) {
      byWeek.set(week, [item]);
    } else {
      bucket.push(item);
    }
  }
  for (const [week, bucket] of byWeek) {
    if (bucket.length > WEEK_CAP) {
      violations.push({
        kind: "week_over",
        week,
        count: bucket.length,
        itemIds: bucket.map((item) => item.id),
      });
    }
  }

  // Gap rule — adjacent-by-date comparison suffices for a min-gap check.
  for (let i = 1; i < sorted.length; i += 1) {
    const prev = sorted[i - 1];
    const next = sorted[i];
    if (prev === undefined || next === undefined) {
      continue;
    }
    const days = dayDiff(prev.date, next.date);
    if (days < MIN_GAP_DAYS && !prev.seasonEvent && !next.seasonEvent) {
      violations.push({
        kind: "gap",
        aId: prev.id,
        bId: next.id,
        aTitle: prev.title,
        bTitle: next.title,
        days,
      });
    }
  }

  // Duplicate works across the whole season plan.
  const byWork = new Map<string, PlannedItem[]>();
  for (const item of sorted) {
    for (const key of item.workKeys) {
      const bucket = byWork.get(key);
      if (bucket === undefined) {
        byWork.set(key, [item]);
      } else if (!bucket.includes(item)) {
        bucket.push(item);
      }
    }
  }
  for (const [work, bucket] of byWork) {
    if (bucket.length > 1) {
      violations.push({
        kind: "duplicate_work",
        work,
        itemIds: bucket.map((item) => item.id),
      });
    }
  }

  // Blocked days — booked events are exempt (they are already committed).
  for (const item of sorted) {
    if (!item.booked && blockedDays.has(item.date)) {
      violations.push({
        kind: "blocked_day",
        itemId: item.id,
        title: item.title,
        day: item.date,
      });
    }
  }

  return violations;
}
