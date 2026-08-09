/** "New since last visit" flags.
 *
 * The cutoff is captured once per session from localStorage and then the
 * stored timestamp advances — so NEW badges hold steady for the whole
 * visit and reset on the next one.
 */

const KEY = "kp.lastVisitAt";

let sessionCutoff: string | null = null;

export function newSinceCutoff(): string | null {
  if (sessionCutoff === null) {
    sessionCutoff = localStorage.getItem(KEY);
    localStorage.setItem(KEY, new Date().toISOString());
  }
  return sessionCutoff;
}

export function isNew(firstSeenAt: string): boolean {
  const cutoff = newSinceCutoff();
  return cutoff !== null && firstSeenAt > cutoff;
}
