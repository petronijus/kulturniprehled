import { describe, expect, it } from "vitest";
import type { Candidate } from "../api/types";
import { decodeFacet, encodeFacet, matchesFacet, poolFacets } from "./facets";

function candidate(overrides: Partial<Candidate> = {}): Candidate {
  return {
    id: "id",
    season_id: "s",
    workspace_id: "w",
    dedup_key: "k",
    lane: "klasika",
    title: "Koncert",
    starts_at: "2026-10-14T19:30:00+02:00",
    ends_at: null,
    venue: "Rudolfinum",
    url: null,
    price_czk: null,
    program: null,
    detail: null,
    enriched_at: null,
    score: null,
    why_cs: null,
    source_type: "sezona",
    source_name: "Česká filharmonie",
    season_event: false,
    tickets_available: null,
    plan_status: "undecided",
    plan_status_at: null,
    note: null,
    first_seen_at: "2026-08-09T10:00:00Z",
    last_seen_at: "2026-08-09T10:00:00Z",
    version: 1,
    created_at: "2026-08-09T10:00:00Z",
    updated_at: "2026-08-09T10:00:00Z",
    ...overrides,
  };
}

describe("poolFacets", () => {
  it("de-duplicates and sorts both lists, ignoring blanks", () => {
    const facets = poolFacets([
      candidate(),
      candidate({ source_name: "Česká filharmonie", venue: "Rudolfinum" }),
      candidate({ source_name: "Ostrava New Music Days", venue: "Ponec" }),
      candidate({ source_name: null, venue: "  " }),
    ]);

    expect(facets.sources).toEqual(["Česká filharmonie", "Ostrava New Music Days"]);
    expect(facets.venues).toEqual(["Ponec", "Rudolfinum"]);
  });
});

describe("facet encoding", () => {
  it("round-trips a value containing a colon", () => {
    const facet = { kind: "venue", value: "Studio: Alta" } as const;
    expect(decodeFacet(encodeFacet(facet))).toEqual(facet);
  });

  it("rejects malformed input", () => {
    expect(decodeFacet("Rudolfinum")).toBeNull();
    expect(decodeFacet("lane:klasika")).toBeNull();
    expect(decodeFacet("venue:")).toBeNull();
  });
});

describe("matchesFacet", () => {
  it("separates an ensemble from a venue of the same name", () => {
    const ensemble = candidate({ source_name: "Ponec", venue: "Rudolfinum" });
    const venue = candidate({ source_name: "Česká filharmonie", venue: "Ponec" });

    expect(matchesFacet(ensemble, { kind: "source", value: "Ponec" })).toBe(true);
    expect(matchesFacet(ensemble, { kind: "venue", value: "Ponec" })).toBe(false);
    expect(matchesFacet(venue, { kind: "venue", value: "Ponec" })).toBe(true);
  });
});
