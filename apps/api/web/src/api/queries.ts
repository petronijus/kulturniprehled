/** Server-state queries. The pool is small (hundreds of rows), so we fetch
 * the whole season once and filter client-side — filters are instant UI
 * state, not server round-trips. */

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { isoToLocalDate, seasonWindowFor } from "../domain/season";
import { ApiError, api } from "./client";
import type {
  BookedEvent,
  CalendarView,
  Candidate,
  HolidayView,
  PoolListResponse,
  Scenario,
  ScenarioListResponse,
  Season,
  SeasonBookedResponse,
} from "./types";

export const queryKeys = {
  season: ["season"] as const,
  pool: (seasonId: string) => ["pool", seasonId] as const,
  scenarios: (seasonId: string) => ["scenarios", seasonId] as const,
  booked: (seasonId: string) => ["booked", seasonId] as const,
  calendar: (from: string, to: string) => ["calendar", from, to] as const,
  holidays: (from: string, to: string) => ["holidays", from, to] as const,
};

/** Get the active season, bootstrapping it when none exists.

The season row is an internal container (pool + scenarios + novelty
cursor) — never a user decision. First visit of a fresh deployment
creates the current cultural-season window silently; a lost creation
race (two tabs) resolves by re-reading `current`. */
async function getOrCreateSeason(): Promise<Season> {
  try {
    return await api<Season>("/v1/season/plans/current");
  } catch (error) {
    if (!(error instanceof ApiError) || error.status !== 404) {
      throw error;
    }
  }
  const window = seasonWindowFor(isoToLocalDate(new Date().toISOString()));
  try {
    return await api<Season>("/v1/season/plans", {
      method: "POST",
      body: JSON.stringify({
        label: window.label,
        starts_on: window.startsOn,
        ends_on: window.endsOn,
      }),
    });
  } catch (error) {
    if (error instanceof ApiError && error.status === 409) {
      return api<Season>("/v1/season/plans/current");
    }
    throw error;
  }
}

export function useCurrentSeason() {
  return useQuery({
    queryKey: queryKeys.season,
    queryFn: getOrCreateSeason,
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
    // While the pool is empty (fresh season, scrape still running) keep
    // polling so the page fills in by itself once /kulturni-sezona lands.
    refetchInterval: (query) => ((query.state.data?.length ?? 0) === 0 ? 30_000 : false),
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
 * week-cap and gap rules and render as immutable chips. Served under the
 * season scope so the login-less trusted-LAN principal can read them. */
export function useBookedEvents(season: Season | undefined) {
  return useQuery({
    queryKey: queryKeys.booked(season?.id ?? "none"),
    queryFn: () => {
      if (season === undefined) {
        throw new Error("no season");
      }
      return api<SeasonBookedResponse>(`/v1/season/plans/${season.id}/booked`).then(
        (r): BookedEvent[] => r.items,
      );
    },
    enabled: season !== undefined,
    staleTime: 5 * 60_000,
  });
}

function calendarPath(from: string, to: string, refresh = false): string {
  const query = new URLSearchParams({ from, to });
  if (refresh) {
    query.set("refresh", "true");
  }
  return `/v1/season/calendar?${query.toString()}`;
}

/** The shared household calendar over the season window — blocked days for
 * the rule engine, entries for the grid. The backend already caches the
 * feed, so a modest refetch keeps a freshly added trip visible without a
 * page reload. */
export function useSharedCalendar(season: Season | undefined) {
  const from = season?.starts_on ?? "";
  const to = season?.ends_on ?? "";
  return useQuery({
    queryKey: queryKeys.calendar(from, to),
    queryFn: () => api<CalendarView>(calendarPath(from, to)),
    enabled: season !== undefined,
    staleTime: 5 * 60_000,
    refetchInterval: 15 * 60_000,
  });
}

/** "I just added that trip" — pull the feed again right now.
 *
 * A plain refetch would be answered from the API's 15-minute feed cache, so
 * this asks the server to skip it. Bought events ride along: a ticket
 * ingested from the phone lands in the grid without a reload. */
export function useRefreshCalendar(season: Season | undefined) {
  const queryClient = useQueryClient();
  const from = season?.starts_on ?? "";
  const to = season?.ends_on ?? "";

  return useMutation({
    mutationFn: () => {
      if (season === undefined) {
        throw new Error("no season");
      }
      return api<CalendarView>(calendarPath(from, to, true));
    },
    onSuccess: (view) => {
      queryClient.setQueryData(queryKeys.calendar(from, to), view);
      void queryClient.invalidateQueries({ queryKey: queryKeys.booked(season?.id ?? "none") });
    },
  });
}

/** Czech public holidays over the season window — a mark in the grid. The
 * feed is public and changes once a year, so this is cached hard and never
 * refetched on an interval. */
export function useHolidays(season: Season | undefined) {
  const from = season?.starts_on ?? "";
  const to = season?.ends_on ?? "";
  return useQuery({
    queryKey: queryKeys.holidays(from, to),
    queryFn: () =>
      api<HolidayView>(
        `/v1/season/holidays?from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}`,
      ),
    enabled: season !== undefined,
    staleTime: 24 * 60 * 60_000,
  });
}
