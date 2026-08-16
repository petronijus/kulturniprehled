/** Ensemble / venue facets for the pool filter.
 *
 * The pool carries two names worth filtering on: `source_name` — who is
 * playing or presenting (Česká filharmonie, Dvořákova Praha) — and `venue`
 * — where (Rudolfinum, MeetFactory). They live in one dropdown, tagged so a
 * venue that shares its name with an ensemble stays distinguishable.
 */

import type { Candidate } from "../api/types";

export type FacetKind = "source" | "venue";

export interface Facet {
  kind: FacetKind;
  value: string;
}

export interface PoolFacets {
  sources: string[];
  venues: string[];
}

function collect(pool: readonly Candidate[], pick: (c: Candidate) => string | null): string[] {
  const seen = new Set<string>();
  for (const candidate of pool) {
    const value = pick(candidate)?.trim();
    if (value !== undefined && value !== "") {
      seen.add(value);
    }
  }
  return [...seen].sort((a, b) => a.localeCompare(b, "cs"));
}

export function poolFacets(pool: readonly Candidate[]): PoolFacets {
  return {
    sources: collect(pool, (c) => c.source_name),
    venues: collect(pool, (c) => c.venue),
  };
}

/** `kind:value` — the dropdown's option value. */
export function encodeFacet(facet: Facet): string {
  return `${facet.kind}:${facet.value}`;
}

export function decodeFacet(raw: string): Facet | null {
  const separator = raw.indexOf(":");
  if (separator === -1) {
    return null;
  }
  const kind = raw.slice(0, separator);
  const value = raw.slice(separator + 1);
  if ((kind !== "source" && kind !== "venue") || value === "") {
    return null;
  }
  return { kind, value };
}

export function matchesFacet(candidate: Candidate, facet: Facet): boolean {
  const field = facet.kind === "source" ? candidate.source_name : candidate.venue;
  return field?.trim() === facet.value;
}
