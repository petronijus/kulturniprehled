/** Wall-calendar math for the season view.
 *
 * Everything works on plain `YYYY-MM-DD` strings interpreted as
 * Europe/Prague wall dates — no Date-with-timezone arithmetic anywhere.
 * API timestamps are converted once at the boundary via `isoToLocalDate`.
 */

export type IsoDate = string; // YYYY-MM-DD
export type IsoMonth = string; // YYYY-MM

const PRAGUE_DATE = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Europe/Prague",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

const PRAGUE_TIME = new Intl.DateTimeFormat("cs-CZ", {
  timeZone: "Europe/Prague",
  hour: "2-digit",
  minute: "2-digit",
});

/** API timestamp (any offset) → Prague wall date. */
export function isoToLocalDate(timestamp: string): IsoDate {
  return PRAGUE_DATE.format(new Date(timestamp));
}

/** API timestamp → Prague wall clock (HH:MM). */
export function isoToLocalTime(timestamp: string): string {
  return PRAGUE_TIME.format(new Date(timestamp));
}

function asUtc(date: IsoDate): Date {
  const [y, m, d] = date.split("-").map(Number);
  if (y === undefined || m === undefined || d === undefined) {
    throw new Error(`invalid date: ${date}`);
  }
  return new Date(Date.UTC(y, m - 1, d));
}

function fromUtc(value: Date): IsoDate {
  return value.toISOString().slice(0, 10);
}

/** Calendar-day difference, positive when `b` is after `a`. */
export function dayDiff(a: IsoDate, b: IsoDate): number {
  return Math.round((asUtc(b).getTime() - asUtc(a).getTime()) / 86_400_000);
}

export function addDays(date: IsoDate, days: number): IsoDate {
  const value = asUtc(date);
  value.setUTCDate(value.getUTCDate() + days);
  return fromUtc(value);
}

/** ISO 8601 week id, e.g. "2026-W53" (year boundary handled correctly). */
export function isoWeek(date: IsoDate): string {
  const value = asUtc(date);
  // Shift to the Thursday of this week; its calendar year is the ISO year.
  const day = value.getUTCDay() || 7;
  value.setUTCDate(value.getUTCDate() + 4 - day);
  const isoYear = value.getUTCFullYear();
  const yearStart = new Date(Date.UTC(isoYear, 0, 1));
  const week = Math.ceil(((value.getTime() - yearStart.getTime()) / 86_400_000 + 1) / 7);
  return `${isoYear}-W${String(week).padStart(2, "0")}`;
}

/** Monday of the week containing `date`. */
export function weekStart(date: IsoDate): IsoDate {
  const value = asUtc(date);
  const day = value.getUTCDay() || 7;
  value.setUTCDate(value.getUTCDate() - (day - 1));
  return fromUtc(value);
}

/** 1–7, Monday = 1. */
export function weekday(date: IsoDate): number {
  return asUtc(date).getUTCDay() || 7;
}

export function monthOf(date: IsoDate): IsoMonth {
  return date.slice(0, 7);
}

/** Inclusive list of months between two dates, e.g. Sep..Jun → 10 items. */
export function monthsBetween(from: IsoDate, to: IsoDate): IsoMonth[] {
  const months: IsoMonth[] = [];
  let [y, m] = from.split("-").map(Number) as [number, number];
  const [endY, endM] = to.split("-").map(Number) as [number, number];
  while (y < endY || (y === endY && m <= endM)) {
    months.push(`${y}-${String(m).padStart(2, "0")}`);
    m += 1;
    if (m > 12) {
      m = 1;
      y += 1;
    }
  }
  return months;
}

export interface MonthGridWeek {
  /** Monday date of this row. */
  start: IsoDate;
  /** The 7 dates Mon..Sun; days outside the month are still present. */
  days: IsoDate[];
}

/** Week rows (Mon..Sun) covering a month. */
export function monthGrid(month: IsoMonth): MonthGridWeek[] {
  const first: IsoDate = `${month}-01`;
  const weeks: MonthGridWeek[] = [];
  let cursor = weekStart(first);
  while (monthOf(cursor) <= month) {
    const days: IsoDate[] = [];
    for (let i = 0; i < 7; i += 1) {
      days.push(addDays(cursor, i));
    }
    weeks.push({ start: cursor, days });
    cursor = addDays(cursor, 7);
    if (monthOf(cursor) > month) {
      break;
    }
  }
  return weeks;
}
