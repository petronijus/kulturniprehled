import { useCallback, useEffect, useMemo, useState } from "react";
import { useApplyScenario, usePatchCandidate } from "../api/mutations";
import {
  useBookedEvents,
  useCurrentSeason,
  usePool,
  useScenarios,
  useSharedCalendar,
} from "../api/queries";
import type { Candidate, PlanStatus } from "../api/types";
import { blockedDaysOf, entriesByDay } from "../domain/calendar";
import { candidateDate, selectedIdsOf, toPlannedItems } from "../domain/planState";
import { monthsBetween } from "../domain/season";
import { computeViolations } from "../domain/violations";
import { cs } from "../i18n/cs";
import { SeasonCalendar } from "./calendar/SeasonCalendar";
import { PlannerDnd } from "./dnd/PlannerDnd";
import { HeaderBar } from "./layout/HeaderBar";
import { ScenarioTabs } from "./layout/ScenarioTabs";
import styles from "./PlannerPage.module.css";
import { CandidatePool } from "./pool/CandidatePool";
import { Toast } from "./ui/Toast";

export function PlannerPage() {
  const seasonQuery = useCurrentSeason();
  const season = seasonQuery.data;
  const poolQuery = usePool(season?.id);
  const scenariosQuery = useScenarios(season?.id);
  const bookedQuery = useBookedEvents(season);
  const calendarQuery = useSharedCalendar(season);

  const [previewScenarioId, setPreviewScenarioId] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [hoveredCandidate, setHoveredCandidate] = useState<Candidate | null>(null);
  const [pinnedCandidates, setPinnedCandidates] = useState<Candidate[]>([]);

  const pool = useMemo(() => poolQuery.data ?? [], [poolQuery.data]);
  const scenarios = useMemo(() => scenariosQuery.data ?? [], [scenariosQuery.data]);
  const booked = useMemo(() => bookedQuery.data ?? [], [bookedQuery.data]);
  const blockedDays = useMemo(() => blockedDaysOf(calendarQuery.data), [calendarQuery.data]);
  const personalByDate = useMemo(() => entriesByDay(calendarQuery.data), [calendarQuery.data]);

  const onConflict = useCallback(() => setToast(cs.conflictToast), []);
  const patchMutation = usePatchCandidate(season?.id ?? "none", onConflict);
  const applyMutation = useApplyScenario(season?.id ?? "none");

  const previewScenario = scenarios.find((scenario) => scenario.id === previewScenarioId);
  const previewMode = previewScenario !== undefined;

  const planIds = useMemo(() => selectedIdsOf(pool), [pool]);
  const selectedIds = useMemo(
    () => (previewScenario !== undefined ? new Set(previewScenario.candidate_ids) : planIds),
    [previewScenario, planIds],
  );

  const violations = useMemo(
    () => computeViolations(toPlannedItems(pool, selectedIds, booked), blockedDays),
    [pool, selectedIds, booked, blockedDays],
  );

  const months = useMemo(
    () => (season !== undefined ? monthsBetween(season.starts_on, season.ends_on) : []),
    [season],
  );

  // Esc exits scenario preview, else clears the pinned card.
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape") {
        return;
      }
      if (previewMode) {
        setPreviewScenarioId(null);
      } else {
        setPinnedCandidates([]);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [previewMode]);

  const togglePin = useCallback((candidate: Candidate) => {
    setPinnedCandidates((current) =>
      current.some((c) => c.id === candidate.id)
        ? current.filter((c) => c.id !== candidate.id)
        : [...current, candidate],
    );
  }, []);

  const setStatus = useCallback(
    (candidate: Candidate, status: PlanStatus) => {
      if (candidate.plan_status !== status) {
        patchMutation.mutate({ candidate, planStatus: status });
      }
    },
    [patchMutation],
  );

  const applyScenario = useCallback(
    (mode: "replace" | "merge") => {
      if (previewScenarioId === null) {
        return;
      }
      applyMutation.mutate(
        { scenarioId: previewScenarioId, mode },
        { onSuccess: () => setPreviewScenarioId(null) },
      );
    },
    [previewScenarioId, applyMutation],
  );

  if (seasonQuery.isPending || (season !== undefined && poolQuery.isPending)) {
    return <div className={styles.centered}>{cs.loading}</div>;
  }
  if (seasonQuery.isError) {
    const status =
      seasonQuery.error instanceof Error && "status" in seasonQuery.error
        ? (seasonQuery.error as { status: number }).status
        : null;
    return (
      <div className={styles.centered}>
        {status === 401 ? (
          <p>{cs.notHome}</p>
        ) : (
          <>
            <p>{cs.loadFailed}</p>
            <button
              type="button"
              className={styles.retry}
              onClick={() => void seasonQuery.refetch()}
            >
              {cs.retry}
            </button>
          </>
        )}
      </div>
    );
  }
  if (season === undefined) {
    return <div className={styles.centered}>{cs.loading}</div>;
  }

  return (
    <div className={styles.page}>
      <HeaderBar
        season={season}
        pool={pool}
        violations={violations}
        calendar={calendarQuery.data}
      />
      <ScenarioTabs
        scenarios={scenarios}
        previewScenarioId={previewScenarioId}
        onPreview={setPreviewScenarioId}
        onApply={applyScenario}
        applying={applyMutation.isPending}
      />
      <PlannerDnd onSetStatus={setStatus}>
        {(dragTargetDate) => (
          <div className={styles.panes}>
            <SeasonCalendar
              season={season}
              pool={pool}
              booked={booked}
              selectedIds={selectedIds}
              planIds={planIds}
              previewMode={previewMode}
              reservedSlots={previewScenario?.reserved_slots ?? []}
              violations={violations}
              blockedDays={blockedDays}
              personalByDate={personalByDate}
              dragTargetDate={dragTargetDate}
              highlightIds={(() => {
                const ids = new Set(pinnedCandidates.map((c) => c.id));
                if (hoveredCandidate !== null) {
                  ids.add(hoveredCandidate.id);
                }
                return ids;
              })()}
              highlightDates={(() => {
                const dates = new Set(pinnedCandidates.map(candidateDate));
                if (hoveredCandidate !== null) {
                  dates.add(candidateDate(hoveredCandidate));
                }
                return dates;
              })()}
              scrollTarget={(() => {
                const last = hoveredCandidate ?? pinnedCandidates[pinnedCandidates.length - 1];
                return last === undefined || last === null ? null : candidateDate(last);
              })()}
            />
            <CandidatePool
              pool={pool}
              months={months}
              onSetStatus={setStatus}
              onHoverChange={setHoveredCandidate}
              pinnedIds={new Set(pinnedCandidates.map((c) => c.id))}
              onTogglePin={togglePin}
              actionsDisabled={previewMode}
            />
          </div>
        )}
      </PlannerDnd>
      <Toast message={toast} onDismiss={() => setToast(null)} />
    </div>
  );
}
