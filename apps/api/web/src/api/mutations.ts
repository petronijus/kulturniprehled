/** Plan mutations with optimistic cache updates and 409 recovery: on a
 * version conflict the server is authoritative — invalidate and refetch,
 * never merge. */

import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api, VersionMismatchError } from "./client";
import { queryKeys } from "./queries";
import type { Candidate, PlanStatus, PlanSummary, SeatWatch } from "./types";

interface PatchArgs {
  candidate: Candidate;
  planStatus: PlanStatus;
}

export function usePatchCandidate(seasonId: string, onConflict: () => void) {
  const queryClient = useQueryClient();
  const poolKey = queryKeys.pool(seasonId);

  return useMutation({
    mutationFn: ({ candidate, planStatus }: PatchArgs) =>
      api<Candidate>(`/v1/season/candidates/${candidate.id}`, {
        method: "PATCH",
        body: JSON.stringify({ version: candidate.version, plan_status: planStatus }),
      }),
    onMutate: async ({ candidate, planStatus }) => {
      await queryClient.cancelQueries({ queryKey: poolKey });
      const previous = queryClient.getQueryData<Candidate[]>(poolKey);
      queryClient.setQueryData<Candidate[]>(poolKey, (pool) =>
        pool?.map((row) => (row.id === candidate.id ? { ...row, plan_status: planStatus } : row)),
      );
      return { previous };
    },
    onError: (error, _args, context) => {
      if (context?.previous !== undefined) {
        queryClient.setQueryData(poolKey, context.previous);
      }
      if (error instanceof VersionMismatchError) {
        onConflict();
      }
      void queryClient.invalidateQueries({ queryKey: poolKey });
    },
    onSuccess: (updated) => {
      queryClient.setQueryData<Candidate[]>(poolKey, (pool) =>
        pool?.map((row) => (row.id === updated.id ? updated : row)),
      );
    },
  });
}

export function useApplyScenario(seasonId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({ scenarioId, mode }: { scenarioId: string; mode: "replace" | "merge" }) =>
      api<PlanSummary>(`/v1/season/scenarios/${scenarioId}/apply`, {
        method: "POST",
        body: JSON.stringify({ mode }),
      }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.pool(seasonId) });
      void queryClient.invalidateQueries({ queryKey: queryKeys.scenarios(seasonId) });
    },
  });
}

interface WatchArgs {
  candidate: Candidate;
  hallUrl: string;
  minAdjacent: number;
  excludeCategories: string[] | null;
}

/** Start watching a sold-out hall — and with it, the checking.
 *
 * There is no second step: one timer works through every watch that exists,
 * so the row IS the schedule.
 */
export function useCreateSeatWatch() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ candidate, hallUrl, minAdjacent, excludeCategories }: WatchArgs) =>
      api<SeatWatch>("/v1/season/watches", {
        method: "POST",
        body: JSON.stringify({
          candidate_id: candidate.id,
          label: `${candidate.title} — ${candidate.starts_at.slice(0, 10)}`,
          starts_at: candidate.starts_at,
          hall_url: hallUrl,
          min_adjacent: minAdjacent,
          exclude_categories: excludeCategories,
        }),
      }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.watches() });
    },
  });
}

/** Stop a watch, or hand it a fresh link when the old one expired. */
export function useUpdateSeatWatch() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ watch, patch }: { watch: SeatWatch; patch: Record<string, unknown> }) =>
      api<SeatWatch>(`/v1/season/watches/${watch.id}`, {
        method: "PATCH",
        body: JSON.stringify({ version: watch.version, ...patch }),
      }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.watches() });
    },
  });
}

export function useDeleteSeatWatch() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (watch: SeatWatch) =>
      api<void>(`/v1/season/watches/${watch.id}`, { method: "DELETE" }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.watches() });
    },
  });
}
