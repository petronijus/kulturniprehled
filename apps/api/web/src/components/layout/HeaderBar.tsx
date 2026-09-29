import type { CalendarView, Candidate, Season } from "../../api/types";
import type { Violation } from "../../domain/violations";
import { en } from "../../i18n/en";
import styles from "./HeaderBar.module.css";
import { ThemeToggle } from "./ThemeToggle";
import { ViolationsSummary } from "./ViolationsSummary";

interface HeaderBarProps {
  season: Season;
  pool: Candidate[];
  violations: Violation[];
  calendar: CalendarView | undefined;
  calendarVisible: boolean;
  onToggleCalendar: () => void;
  onRefreshCalendar: () => void;
  calendarRefreshing: boolean;
}

/** Local wall-clock of the last successful feed read, for the tooltip. */
function fetchedAtLabel(calendar: CalendarView | undefined): string | null {
  if (calendar?.fetched_at === undefined || calendar.fetched_at === null) {
    return null;
  }
  const time = new Date(calendar.fetched_at).toLocaleTimeString("en-GB", {
    hour: "2-digit",
    minute: "2-digit",
  });
  return en.calendar.updated(time);
}

export function HeaderBar({
  season,
  pool,
  violations,
  calendar,
  calendarVisible,
  onToggleCalendar,
  onRefreshCalendar,
  calendarRefreshing,
}: HeaderBarProps) {
  const selected = pool.filter((candidate) => candidate.plan_status === "selected").length;
  const undecided = pool.filter((candidate) => candidate.plan_status === "undecided").length;
  const fetchedAt = fetchedAtLabel(calendar);
  const refreshTitle = calendarRefreshing
    ? en.calendar.refreshing
    : fetchedAt === null
      ? en.calendar.refresh
      : `${en.calendar.refresh} · ${fetchedAt}`;

  return (
    <header className={styles.bar}>
      <div className={styles.titleBlock}>
        <h1 className={styles.title}>
          {en.appTitle} <span className={styles.seasonLabel}>{season.label}</span>
        </h1>
        <p className={styles.counts}>{en.counts(selected, undecided)}</p>
      </div>
      <div className={styles.tools}>
        {calendar !== undefined && calendar.available === false && (
          <span className={styles.calendarWarning}>
            {calendar.unavailable_reason === "not_configured"
              ? en.calendar.notConfigured
              : en.calendar.unavailable}
          </span>
        )}
        <button
          type="button"
          className={`${styles.calendarToggle} ${calendarVisible ? "" : styles.calendarOff}`}
          onClick={onToggleCalendar}
          aria-pressed={calendarVisible}
          title={calendarVisible ? en.calendar.hide : en.calendar.show}
        >
          <span aria-hidden="true">🗓</span> {en.calendar.layerLabel}
        </button>
        <button
          type="button"
          className={styles.calendarRefresh}
          onClick={onRefreshCalendar}
          disabled={calendarRefreshing}
          title={refreshTitle}
          aria-label={en.calendar.refresh}
        >
          <span
            className={`${styles.refreshIcon} ${calendarRefreshing ? styles.spinning : ""}`}
            aria-hidden="true"
          >
            ↻
          </span>
        </button>
        <ViolationsSummary violations={violations} pool={pool} />
        <ThemeToggle />
      </div>
    </header>
  );
}
