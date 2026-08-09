/** Server-state queries. The pool is small (hundreds of rows), so we fetch
 * the whole season once and filter client-side — filters are instant UI
 * state, not server round-trips. */

import { useQuery } from "@tanstack/react-query";
import { api } from "./client";
import type {
  BookedEvent,
  Candidate,
  EventListResponse,
  PoolListResponse,
  Scenario,
  ScenarioListResponse,
  Season,
} from "./types";

export const queryKeys = {
  season: ["season"] as const,
  pool: (seasonId: string) => ["pool", seasonId] as const,
  scenarios: (seasonId: string) => ["scenarios", seasonId] as const,
  booked: (seasonId: string) => ["booked", seasonId] as const,
};

export function useCurrentSeason() {
  return useQuery({
    queryKey: queryKeys.season,
    queryFn: () => api<Season>("/v1/season/plans/current"),
    retry: (failureCount, error) =>
      failureCount < 2 && !(error instanceof Error && "status" in error),
    staleTime: 5 * 60_000,
  });
}

async function fetchWholePool(seasonId: string): Promise<Candidate[]> {
  const items: Candidate[] = [];
  let offset = 0;
  for (;;) {
    const page = await api<PoolListResponse>(
      `/v1/season/plans/${seasonId}/pool?limit=1000&offset=${offset}`,
    );
    items.push(...page.items);
    offset += page.items.length;
    if (offset >= page.total || page.items.length === 0) {
      return items;
    }
  }
}

export function usePool(seasonId: string | undefined) {
  return useQuery({
    queryKey: queryKeys.pool(seasonId ?? "none"),
    queryFn: () => {
      if (seasonId === undefined) {
        throw new Error("no season");
      }
      return fetchWholePool(seasonId);
    },
    enabled: seasonId !== undefined,
    staleTime: 60_000,
  });
}

export function useScenarios(seasonId: string | undefined) {
  return useQuery({
    queryKey: queryKeys.scenarios(seasonId ?? "none"),
    queryFn: () => {
      if (seasonId === undefined) {
        throw new Error("no season");
      }
      return api<ScenarioListResponse>(`/v1/season/plans/${seasonId}/scenarios`).then(
        (r): Scenario[] => r.items,
      );
    },
    enabled: seasonId !== undefined,
    staleTime: 60_000,
  });
}

/** Booked KP events over the season window — they participate in the
 * week-cap and gap rules and render as immutable chips. */
export function useBookedEvents(season: Season | undefined) {
  return useQuery({
    queryKey: queryKeys.booked(season?.id ?? "none"),
    queryFn: () => {
      if (season === undefined) {
        throw new Error("no season");
      }
      const from = `${season.starts_on}T00:00:00Z`;
      const to = `${season.ends_on}T23:59:59Z`;
      const params = new URLSearchParams({ starts_from: from, starts_to: to, limit: "500" });
      return api<EventListResponse>(`/v1/events?${params.toString()}`).then(
        (r): BookedEvent[] => r.items,
      );
    },
    enabled: season !== undefined,
    staleTime: 5 * 60_000,
  });
}
