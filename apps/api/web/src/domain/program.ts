/** Programme entries → one printable line per piece.
 *
 * Every lane names its two halves differently — klasika sends
 * `composer`/`work`, divadlo `author`/`play`, film `director`/`film` — and
 * scrapers fill in whichever half they could read. The card renders author
 * and piece as separate columns, so the split survives all the way to the
 * layout instead of being flattened into one string here.
 */

import type { ProgramEntry } from "../api/types";

export interface ProgramLine {
  /** Composer, playwright or director; null when the source never named one. */
  author: string | null;
  /** Work, play or film title; null when only the author is known. */
  work: string | null;
}

function firstText(...values: readonly unknown[]): string | null {
  for (const value of values) {
    if (typeof value === "string" && value.trim() !== "") {
      return value.trim();
    }
  }
  return null;
}

/** Drops entries that carry neither half — a half-line still informs. */
export function programLines(program: readonly ProgramEntry[] | null): ProgramLine[] {
  if (program === null) {
    return [];
  }
  return program
    .map((entry) => ({
      author: firstText(entry.composer, entry.author, entry.director),
      work: firstText(entry.work, entry.play, entry.film),
    }))
    .filter((line) => line.author !== null || line.work !== null);
}
