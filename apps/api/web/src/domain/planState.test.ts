import { describe, expect, it } from "vitest";
import type { Candidate } from "../api/types";
import { candidateWorkKeys } from "./planState";

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
    source_name: "PKF – Prague Philharmonia",
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

describe("candidateWorkKeys", () => {
  it("keys a fully named piece", () => {
    const keys = candidateWorkKeys(
      candidate({ program: [{ composer: "Joseph Haydn", work: "Symfonie č. 104 D dur" }] }),
    );
    expect(keys).toEqual(["joseph haydn|symfonie c 104 d dur"]);
  });

  it("ignores a composer whose work was never read", () => {
    // Old WebFetch scrapes wrote `work: ""` when they could only recover the
    // composer from the concert title. Keying those made two unrelated
    // Haydn evenings collide as "the same work twice".
    const keys = candidateWorkKeys(
      candidate({
        program: [
          { composer: "Joseph Haydn", work: "" },
          { composer: "Jean-Philippe Rameau", work: "" },
        ],
      }),
    );
    expect(keys).toEqual([]);
  });

  it("ignores an entry the scraper left without a composer", () => {
    expect(candidateWorkKeys(candidate({ program: [{ composer: "", work: "Requiem" }] }))).toEqual(
      [],
    );
  });

  it("keeps the named pieces of a partly read programme", () => {
    const keys = candidateWorkKeys(
      candidate({
        program: [{ composer: "Antonín Dvořák" }, { composer: "Bedřich Smetana", work: "Vltava" }],
      }),
    );
    expect(keys).toEqual(["bedrich smetana|vltava"]);
  });

  it("reads the divadlo and film halves under their own names", () => {
    const keys = candidateWorkKeys(
      candidate({
        lane: "divadlo",
        program: [
          { author: "Anton Pavlovič Čechov", play: "Racek" },
          { director: "Agnès Varda", film: "Cléo od pěti do sedmi" },
        ],
      }),
    );
    expect(keys).toEqual(["anton pavlovic cechov|racek", "agnes varda|cleo od peti do sedmi"]);
  });
});
