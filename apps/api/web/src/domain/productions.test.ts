import { describe, expect, it } from "vitest";
import type { BookedEvent, Candidate } from "../api/types";
import type { ProductionGroup } from "./productions";
import { groupProductions, groupStatus, isProductionBooked, productionKey } from "./productions";

function firstGroup(pool: Candidate[]): ProductionGroup {
  const group = groupProductions(pool)[0];
  if (group === undefined) {
    throw new Error("expected at least one group");
  }
  return group;
}

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

function booked(overrides: Partial<BookedEvent> = {}): BookedEvent {
  return {
    id: "b1",
    title: "Koupený koncert",
    category: "concert",
    starts_at: "2026-10-14T19:00:00+02:00",
    ...overrides,
  };
}

describe("productionKey", () => {
  it("ignores query, hash, trailing slash and www", () => {
    const a = candidate({ url: "https://www.narodni-divadlo.cz/cs/predstaveni/rusalka-61064/" });
    const b = candidate({
      url: "https://narodni-divadlo.cz/cs/predstaveni/rusalka-61064?ref=x#top",
    });
    expect(productionKey(a)).toBe(productionKey(b));
  });

  it("maps host aliases so both ND domains group together", () => {
    const a = candidate({ url: "https://www.nationaltheatre.cz/cs/predstaveni/rusalka-61064" });
    const b = candidate({ url: "https://www.narodni-divadlo.cz/cs/predstaveni/rusalka-61064" });
    expect(productionKey(a)).toBe(productionKey(b));
  });

  it("falls back to the diacritics-normalized title without a URL", () => {
    const a = candidate({ url: null, title: "Pelléas a Mélisanda" });
    const b = candidate({ url: null, title: "pelleas a melisanda" });
    expect(productionKey(a)).toBe(productionKey(b));
  });

  it("keeps lanes apart even for the same URL", () => {
    const a = candidate({ url: "https://example.cz/x" });
    const b = candidate({ url: "https://example.cz/x", lane: "elektronika" });
    expect(productionKey(a)).not.toBe(productionKey(b));
  });
});

describe("groupProductions", () => {
  const run = [
    candidate({ id: "c2", url: "https://nd.cz/rusalka", starts_at: "2026-10-21T19:00:00+02:00" }),
    candidate({ id: "c1", url: "https://nd.cz/rusalka", starts_at: "2026-09-19T18:00:00+02:00" }),
    candidate({ id: "x", url: "https://fok.cz/mahler7", starts_at: "2027-01-27T19:30:00+01:00" }),
  ];

  it("groups by production and sorts dates chronologically", () => {
    const groups = groupProductions(run);
    expect(groups).toHaveLength(2);
    expect(groups[0]?.candidates.map((c) => c.id)).toEqual(["c1", "c2"]);
  });

  it("primary skips rejected dates, richest prefers the enriched one", () => {
    const groups = groupProductions([
      candidate({
        id: "c1",
        url: "https://nd.cz/rusalka",
        starts_at: "2026-09-19T18:00:00+02:00",
        plan_status: "rejected",
      }),
      candidate({
        id: "c2",
        url: "https://nd.cz/rusalka",
        starts_at: "2026-10-21T19:00:00+02:00",
        program: [{ composer: "Antonín Dvořák", work: "Rusalka" }],
        why_cs: "…",
      }),
    ]);
    expect(groups[0]?.primary.id).toBe("c2");
    expect(groups[0]?.richest.id).toBe("c2");
  });
});

describe("groupStatus", () => {
  const at = (statuses: Candidate["plan_status"][]) =>
    firstGroup(
      statuses.map((plan_status, index) =>
        candidate({
          id: `c${index}`,
          url: "https://nd.cz/rusalka",
          starts_at: `2026-10-${String(10 + index)}T19:00:00+02:00`,
          plan_status,
        }),
      ),
    );

  it("one selected date marks the production selected", () => {
    expect(groupStatus(at(["rejected", "selected", "undecided"]))).toBe("selected");
  });

  it("only a fully rejected production is rejected", () => {
    expect(groupStatus(at(["rejected", "rejected"]))).toBe("rejected");
    expect(groupStatus(at(["rejected", "undecided"]))).toBe("undecided");
  });
});

describe("isProductionBooked", () => {
  const pelleas = firstGroup([
    candidate({
      id: "c1",
      title: "Pelleas a Melisanda",
      url: "https://nd.cz/pelleas",
      starts_at: "2026-10-15T19:00:00+02:00",
    }),
    candidate({
      id: "c2",
      title: "Pelleas a Melisanda",
      url: "https://nd.cz/pelleas",
      starts_at: "2026-10-31T18:00:00+01:00",
    }),
  ]);

  it("hides the whole production when one date matches a booked title", () => {
    const event = booked({
      title: "Debussy: Pelléas a Mélisanda",
      starts_at: "2026-10-31T18:00:00+01:00",
    });
    expect(isProductionBooked(pelleas, [event])).toBe(true);
  });

  it("does not match a same-day booked event with an unrelated title", () => {
    const event = booked({ title: "Grigorij Sokolov", starts_at: "2026-10-31T19:30:00+01:00" });
    expect(isProductionBooked(pelleas, [event])).toBe(false);
  });

  it("does not match the same title on a different day", () => {
    const event = booked({
      title: "Debussy: Pelléas a Mélisanda",
      starts_at: "2026-11-05T19:00:00+01:00",
    });
    expect(isProductionBooked(pelleas, [event])).toBe(false);
  });

  it("never matches on stopwords alone", () => {
    const group = firstGroup([
      candidate({ id: "c1", title: "Koncert pro Prahu", url: "https://x.cz/a" }),
    ]);
    const event = booked({ title: "Koncert v opeře", starts_at: "2026-10-14T20:00:00+02:00" });
    expect(isProductionBooked(group, [event])).toBe(false);
  });
});
