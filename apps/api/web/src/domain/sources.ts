/** Ensemble / festival logo registry.
 *
 * Logos live in `public/logos/<slug>.png` (official favicons, fetched
 * once — drop a better file over any of them anytime; the UI only ever
 * resizes). Aggregator sources (Songkick, GoOut) deliberately have no
 * logo and fall back to the text-only badge.
 */

const SLUGS: Record<string, string> = {
  "ceska filharmonie": "ceska-filharmonie",
  "cesky spolek pro komorni hudbu": "cesky-spolek-pro-komorni-hudbu",
  "dvorakova praha": "dvorakova-praha",
  "pkf prague philharmonia": "pkf",
  socr: "socr",
  fok: "fok",
  "palac akropolis": "palac-akropolis",
  "prague sounds": "prague-sounds",
  "narodni divadlo": "narodni-divadlo",
  klangsystematiek: "klangsystematiek",
  ankali: "ankali",
  lunchmeat: "lunchmeat",
  roxy: "roxy",
  "prazske jaro": "prazske-jaro",
  "orchestr berg": "orchestr-berg",
  "cross club": "cross-club",
  punctum: "punctum",
};

function normalizeName(value: string): string {
  return value
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9 ]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/** Logo URL for a source name, or null when we have none. */
export function logoFor(sourceName: string): string | null {
  const slug = SLUGS[normalizeName(sourceName)];
  return slug === undefined ? null : `${import.meta.env.BASE_URL}logos/${slug}.png`;
}
