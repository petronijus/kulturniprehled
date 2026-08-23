import { useCallback, useEffect, useMemo, useState } from "react";
import { useApplyScenario, usePatchCandidate } from "../api/mutations";
import {
  useBookedEvents,
  useCurrentSeason,
  useHolidays,
  usePool,
  useScenarios,
  useSharedCalendar,
} from "../api/queries";
import type { CalendarEntry, Candidate, PlanStatus } from "../api/types";
import { blockedDaysOf, entriesByDay, holidaysByDay } from "../domain/calendar";
import { candidateDate, selectedIdsOf, toPlannedItems } from "../domain/planState";
import type { ProductionGroup } from "../domain/productions";
import { groupProductions } from "../domain/productions";
import type { IsoDate } from "../domain/season";
import { monthsBetween } from "../domain/season";
import { computeViolations } from "../domain/violations";
import { cs } from "../i18n/cs";
import { useCalendarVisible } from "../state/calendarLayer";
import { SeasonCalendar } from "./calendar/SeasonCalendar";
import { PlannerDnd } from "./dnd/PlannerDnd";
import { HeaderBar } from "./layout/HeaderBar";
import { ScenarioTabs } from "./layout/ScenarioTabs";
import styles from "./PlannerPage.module.css";
import { CandidatePool } from "./pool/CandidatePool";
import { Toast } from "./ui/Toast";

// Hiding the calendar layer is presentational only — the rule engine keeps
// its real blocked-day set, so violations survive the toggle.
const NO_ENTRIES: ReadonlyMap<IsoDate, CalendarEntry[]> = new Map();
const NO_DAYS: ReadonlySet<IsoDate> = new Set<IsoDate>();

export function PlannerPage() {
  const seasonQuery = useCurrentSeason();
  const season = seasonQuery.data;
  const poolQuery = usePool(season?.id);
  const scenariosQuery = useScenarios(season?.id);
  const bookedQuery = useBookedEvents(season);
  const calendarQuery = useSharedCalendar(season);
  const holidaysQuery = useHolidays(season);
  const [calendarVisible, toggleCalendar] = useCalendarVisible();

  const [previewScenarioId, setPreviewScenarioId] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  // Hover/pin are tracked by production key so they survive pool refetches;
  // the member candidates are re-derived from the current pool each render.
  const [hoveredKey, setHoveredKey] = useState<string | null>(null);
  const [pinnedKeys, setPinnedKeys] = useState<string[]>([]);

  const pool = useMemo(() => poolQuery.data ?? [], [poolQuery.data]);
  const groups = useMemo(() => groupProductions(pool), [pool]);
  const groupsByKey = useMemo(() => new Map(groups.map((group) => [group.key, group])), [groups]);
  const scenarios = useMemo(() => scenariosQuery.data ?? [], [scenariosQuery.data]);
  const booked = useMemo(() => bookedQuery.data ?? [], [bookedQuery.data]);
  const blockedDays = useMemo(() => blockedDaysOf(calendarQuery.data), [calendarQuery.data]);
  const personalByDate = useMemo(() => entriesByDay(calendarQuery.data), [calendarQuery.data]);
  const holidaysByDate = useMemo(() => holidaysByDay(holidaysQuery.data), [holidaysQuery.data]);

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
        setPinnedKeys([]);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [previewMode]);

  const togglePin = useCallback((group: ProductionGroup) => {
    setPinnedKeys((current) =>
      current.includes(group.key)
        ? current.filter((key) => key !== group.key)
        : [...current, group.key],
    );
  }, []);

  const onHoverChange = useCallback((group: ProductionGroup | null) => {
    setHoveredKey(group === null ? null : group.key);
  }, []);

  // A hovered or pinned card lights up every date of its production.
  const { highlightIds, highlightDates, scrollTarget } = useMemo(() => {
    const ids = new Set<string>();
    const dates = new Set<IsoDate>();
    const activeKeys = hoveredKey !== null ? [...pinnedKeys, hoveredKey] : pinnedKeys;
    let target: IsoDate | null = null;
    for (const key of activeKeys) {
      const group = groupsByKey.get(key);
      if (group === undefined) {
        continue;
      }
      for (const candidate of group.candidates) {
        ids.add(candidate.id);
        dates.add(candidateDate(candidate));
      }
      target = candidateDate(group.primary);
    }
    return { highlightIds: ids, highlightDates: dates, scrollTarget: target };
  }, [hoveredKey, pinnedKeys, groupsByKey]);

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
        calendarVisible={calendarVisible}
        onToggleCalendar={toggleCalendar}
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
              blockedDays={calendarVisible ? blockedDays : NO_DAYS}
              personalByDate={calendarVisible ? personalByDate : NO_ENTRIES}
              holidaysByDate={holidaysByDate}
              dragTargetDate={dragTargetDate}
              highlightIds={highlightIds}
              highlightDates={highlightDates}
              scrollTarget={scrollTarget}
            />
            <CandidatePool
              pool={pool}
              groups={groups}
              booked={booked}
              months={months}
              onSetStatus={setStatus}
              onHoverChange={onHoverChange}
              pinnedKeys={new Set(pinnedKeys)}
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
