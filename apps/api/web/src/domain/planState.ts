/** Derivations from the raw pool into what the calendar + rules consume. */

import type { BookedEvent, Candidate } from "../api/types";
import type { IsoDate } from "./season";
import { isoToLocalDate } from "./season";
import type { PlannedItem } from "./violations";
import { workKey } from "./violations";

export function candidateDate(candidate: Candidate): IsoDate {
  return isoToLocalDate(candidate.starts_at);
}

export function candidateWorkKeys(candidate: Candidate): string[] {
  if (candidate.program === null) {
    return [];
  }
  const keys: string[] = [];
  for (const entry of candidate.program) {
    const author = entry.composer ?? entry.author ?? entry.director;
    const work = entry.work ?? entry.play ?? entry.film;
    if (typeof author === "string" && typeof work === "string") {
      keys.push(workKey(author, work));
    }
  }
  return keys;
}

/** Build the rule-engine input from a set of selected candidate ids.
 *
 * Taking the selection as an explicit id set (instead of reading
 * `plan_status`) lets the same function serve both the live plan and a
 * scenario preview.
 */
export function toPlannedItems(
  pool: readonly Candidate[],
  selectedIds: ReadonlySet<string>,
  booked: readonly BookedEvent[],
): PlannedItem[] {
  const items: PlannedItem[] = [];
  for (const candidate of pool) {
    if (selectedIds.has(candidate.id)) {
      items.push({
        id: candidate.id,
        title: candidate.title,
        date: candidateDate(candidate),
        seasonEvent: candidate.season_event,
        workKeys: candidateWorkKeys(candidate),
        booked: false,
      });
    }
  }
  for (const event of booked) {
    items.push({
      id: `booked-${event.id}`,
      title: event.title,
      date: isoToLocalDate(event.starts_at),
      seasonEvent: false,
      workKeys: [],
      booked: true,
    });
  }
  return items;
}

export function selectedIdsOf(pool: readonly Candidate[]): Set<string> {
  return new Set(pool.filter((c) => c.plan_status === "selected").map((c) => c.id));
}
