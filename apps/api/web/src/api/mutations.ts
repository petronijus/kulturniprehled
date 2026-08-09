/** Plan mutations with optimistic cache updates and 409 recovery: on a
 * version conflict the server is authoritative — invalidate and refetch,
 * never merge. */

import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api, VersionMismatchError } from "./client";
import { queryKeys } from "./queries";
import type { Candidate, PlanStatus, PlanSummary } from "./types";

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
