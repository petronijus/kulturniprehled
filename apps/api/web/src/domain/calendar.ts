/** The shared household calendar as the planner needs it.
 *
 * The API already classified the feed (blocked days vs. timed conflicts);
 * this module only reshapes the flat entry list for rendering and derives
 * the blocked-day set the rule engine takes.
 */

import type { CalendarEntry, CalendarView, HolidayView } from "../api/types";
import { cs } from "../i18n/cs";
import type { IsoDate } from "./season";
import { isoToLocalTime } from "./season";

export function blockedDaysOf(view: CalendarView | undefined): ReadonlySet<IsoDate> {
  return new Set(view?.blocked_days ?? []);
}

export function entriesByDay(
  view: CalendarView | undefined,
): ReadonlyMap<IsoDate, CalendarEntry[]> {
  const byDay = new Map<IsoDate, CalendarEntry[]>();
  for (const entry of view?.entries ?? []) {
    const bucket = byDay.get(entry.day);
    if (bucket === undefined) {
      byDay.set(entry.day, [entry]);
    } else {
      bucket.push(entry);
    }
  }
  return byDay;
}

/** Cell label: a timed event leads with its start, a continuation day leads
 * with where it is heading, an all-day span carries its day counter. */
export function entryLabel(entry: CalendarEntry): string {
  const counter = entry.span_days > 1 ? ` ${entry.span_index + 1}/${entry.span_days}` : "";
  if (entry.all_day) {
    return `${entry.title}${counter}`;
  }
  if (entry.span_index > 0 && entry.ends_at !== null) {
    return `${cs.calendar.until} ${isoToLocalTime(entry.ends_at)} ${entry.title}`;
  }
  return entry.starts_at === null
    ? entry.title
    : `${isoToLocalTime(entry.starts_at)} ${entry.title}`;
}

/** Holiday titles keyed by day, for the grid's holiday mark. */
export function holidaysByDay(view: HolidayView | undefined): ReadonlyMap<IsoDate, string> {
  return new Map((view?.days ?? []).map((holiday) => [holiday.day, holiday.title]));
}

/** Full-day tooltip: every entry of the day, one per line. */
export function dayTooltip(entries: readonly CalendarEntry[]): string {
  return entries.map(entryLabel).join("\n");
}
