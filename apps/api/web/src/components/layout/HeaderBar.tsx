import type { CalendarView, Candidate, Season } from "../../api/types";
import type { Violation } from "../../domain/violations";
import { cs } from "../../i18n/cs";
import styles from "./HeaderBar.module.css";
import { ThemeToggle } from "./ThemeToggle";
import { ViolationsSummary } from "./ViolationsSummary";

interface HeaderBarProps {
  season: Season;
  pool: Candidate[];
  violations: Violation[];
  calendar: CalendarView | undefined;
}

export function HeaderBar({ season, pool, violations, calendar }: HeaderBarProps) {
  const selected = pool.filter((candidate) => candidate.plan_status === "selected").length;
  const undecided = pool.filter((candidate) => candidate.plan_status === "undecided").length;

  return (
    <header className={styles.bar}>
      <div className={styles.titleBlock}>
        <h1 className={styles.title}>
          {cs.appTitle} <span className={styles.seasonLabel}>{season.label}</span>
        </h1>
        <p className={styles.counts}>{cs.counts(selected, undecided)}</p>
      </div>
      <div className={styles.tools}>
        {calendar !== undefined && calendar.available === false && (
          <span className={styles.calendarWarning}>
            {calendar.unavailable_reason === "not_configured"
              ? cs.calendar.notConfigured
              : cs.calendar.unavailable}
          </span>
        )}
        <ViolationsSummary violations={violations} pool={pool} />
        <ThemeToggle />
      </div>
    </header>
  );
}
