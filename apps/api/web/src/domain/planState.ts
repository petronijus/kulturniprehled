/** Derivations from the raw pool into what the calendar + rules consume. */

import type { BookedEvent, Candidate } from "../api/types";
import { programLines } from "./program";
import type { IsoDate } from "./season";
import { isoToLocalDate } from "./season";
import type { PlannedItem } from "./violations";
import { workKey } from "./violations";

export function candidateDate(candidate: Candidate): IsoDate {
  return isoToLocalDate(candidate.starts_at);
}

/** Work keys for the duplicate-work rule — only from fully named pieces.
 *
 * Built on `programLines` so this cannot drift from what the card prints.
 * The hand-rolled version used `??`, which passes an empty string through,
 * and a scrape that had read a composer off the title but no work turned
 * into the key `"joseph haydn|"`. Two such concerts then collided and the
 * planner reported a duplicate work where neither work was even known —
 * `kp_validate.work_keys` never had the bug, because `"" or …` is falsy in
 * Python and the entry falls out on its own.
 */
export function candidateWorkKeys(candidate: Candidate): string[] {
  const keys: string[] = [];
  for (const line of programLines(candidate.program)) {
    if (line.author !== null && line.work !== null) {
      keys.push(workKey(line.author, line.work));
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
