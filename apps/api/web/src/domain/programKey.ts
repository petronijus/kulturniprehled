/** Identity of a programme piece — the SPA half of a two-sided canon.
 *
 * The API stores media links keyed by a folded `author|work` string
 * (`apps/api/src/kp_api/domain/program_key.py`); the card folds the line it
 * is about to render the same way to find them. **Both sides are tested
 * against the same fixtures — change one, change the other.**
 */

const NON_ALNUM = /[^a-z0-9]+/g;
const COMBINING = /\p{M}/gu;

function fold(text: string): string {
  return text.toLowerCase().normalize("NFKD").replace(COMBINING, "").replace(NON_ALNUM, " ").trim();
}

/** `null` for a line that folds away to nothing — not a lookupable piece. */
export function programKey(author: string | null, work: string | null): string | null {
  const key = `${fold(author ?? "")}|${fold(work ?? "")}`;
  return key === "|" ? null : key;
}

/** What to search for when the piece has no resolved link yet. */
export function programQuery(author: string | null, work: string | null): string {
  return [author, work].filter((part): part is string => part !== null).join(" ");
}
