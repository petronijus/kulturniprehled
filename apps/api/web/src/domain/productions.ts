/** Multi-date productions.
 *
 * Opera runs and repeated subscription concerts arrive as one pool row per
 * date, all sharing the production's URL — the same identity the backend
 * dedup_key is built from, minus the date. Grouping by that identity is what
 * lets the pool show one card per production, light up every date on hover,
 * and retire the whole production once one of its dates is bought.
 */

import type { BookedEvent, Candidate, PlanStatus } from "../api/types";
import { candidateDate } from "./planState";
import type { IsoDate } from "./season";
import { isoToLocalDate } from "./season";

/** Venues serving the same pages under more than one hostname — mirror of
 * the scraper-side alias table (skills/kulturni-sezona dedup recipe). */
const HOST_ALIASES: Record<string, string> = {
  "nationaltheatre.cz": "narodni-divadlo.cz",
};

function stripDiacritics(value: string): string {
  return value.normalize("NFD").replace(/\p{M}/gu, "");
}

function normalizeText(value: string): string {
  return stripDiacritics(value.toLowerCase())
    .replace(/[^a-z0-9 ]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function canonicalUrl(url: string): string {
  const bare = url
    .toLowerCase()
    .replace(/[#?].*$/, "")
    .replace(/\/+$/, "")
    .replace(/^https?:\/\/(www\.)?/, "");
  const slash = bare.indexOf("/");
  const host = slash === -1 ? bare : bare.slice(0, slash);
  const path = slash === -1 ? "" : bare.slice(slash);
  return `${HOST_ALIASES[host] ?? host}${path}`;
}

/** Production identity: the dedup_key recipe without its date component. */
export function productionKey(candidate: Candidate): string {
  const ident =
    candidate.url !== null && candidate.url !== ""
      ? canonicalUrl(candidate.url)
      : normalizeText(candidate.title);
  return `${candidate.lane}|${ident}`;
}

export interface ProductionGroup {
  key: string;
  /** Every date of the production, sorted by starts_at. */
  candidates: Candidate[];
  /** The date a card-level action (drag, single-date select) refers to:
   * the earliest not-yet-rejected date, falling back to the earliest. */
  primary: Candidate;
  /** The member whose card content (program, why, score) reads best. */
  richest: Candidate;
}

function pickPrimary(first: Candidate, candidates: readonly Candidate[]): Candidate {
  return candidates.find((c) => c.plan_status !== "rejected") ?? first;
}

function richness(candidate: Candidate): number {
  let score = 0;
  if (candidate.program !== null && candidate.program.length > 0) {
    score += 4;
  }
  if (candidate.why_cs !== null) {
    score += 2;
  }
  if (candidate.score !== null) {
    score += 1;
  }
  return score;
}

function pickRichest(first: Candidate, candidates: readonly Candidate[]): Candidate {
  let best = first;
  for (const candidate of candidates) {
    if (richness(candidate) > richness(best)) {
      best = candidate;
    }
  }
  return best;
}

/** Group the pool into productions; group order follows first appearance. */
export function groupProductions(pool: readonly Candidate[]): ProductionGroup[] {
  const byKey = new Map<string, Candidate[]>();
  for (const candidate of pool) {
    const key = productionKey(candidate);
    const bucket = byKey.get(key);
    if (bucket === undefined) {
      byKey.set(key, [candidate]);
    } else {
      bucket.push(candidate);
    }
  }
  const groups: ProductionGroup[] = [];
  for (const [key, candidates] of byKey) {
    candidates.sort((a, b) => a.starts_at.localeCompare(b.starts_at));
    const first = candidates[0];
    if (first === undefined) {
      continue;
    }
    groups.push({
      key,
      candidates,
      primary: pickPrimary(first, candidates),
      richest: pickRichest(first, candidates),
    });
  }
  return groups;
}

/** Aggregate plan status: one date in the plan marks the whole production
 * selected; only a fully rejected production reads rejected. */
export function groupStatus(group: ProductionGroup): PlanStatus {
  if (group.candidates.some((c) => c.plan_status === "selected")) {
    return "selected";
  }
  if (group.candidates.every((c) => c.plan_status === "rejected")) {
    return "rejected";
  }
  return "undecided";
}

/** Words that carry no identity — never enough to match a booked title. */
const TITLE_STOPWORDS = new Set([
  "koncert",
  "opera",
  "balet",
  "praha",
  "prague",
  "orchestr",
  "filharmonie",
  "symfonicky",
  "divadlo",
  "festival",
]);

function significantTokens(title: string): Set<string> {
  const tokens = new Set<string>();
  for (const token of normalizeText(title).split(" ")) {
    if (token.length >= 4 && !TITLE_STOPWORDS.has(token)) {
      tokens.add(token);
    }
  }
  return tokens;
}

/** True when one of the production's dates has been bought: a booked KP
 * event on the same local day whose title shares at least one significant
 * token. Booked events carry no URL, so the title is all there is to
 * match on — same-day narrows it enough for one token to be safe. */
export function isProductionBooked(
  group: ProductionGroup,
  booked: readonly BookedEvent[],
): boolean {
  if (booked.length === 0) {
    return false;
  }
  const bookedTokensByDate = new Map<IsoDate, Set<string>[]>();
  for (const event of booked) {
    const date = isoToLocalDate(event.starts_at);
    const bucket = bookedTokensByDate.get(date);
    const tokens = significantTokens(event.title);
    if (bucket === undefined) {
      bookedTokensByDate.set(date, [tokens]);
    } else {
      bucket.push(tokens);
    }
  }
  for (const candidate of group.candidates) {
    const sameDay = bookedTokensByDate.get(candidateDate(candidate));
    if (sameDay === undefined) {
      continue;
    }
    const own = significantTokens(candidate.title);
    for (const tokens of sameDay) {
      for (const token of own) {
        if (tokens.has(token)) {
          return true;
        }
      }
    }
  }
  return false;
}
