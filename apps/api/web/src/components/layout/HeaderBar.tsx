import type { Candidate, Season } from "../../api/types";
import type { Violation } from "../../domain/violations";
import { cs } from "../../i18n/cs";
import styles from "./HeaderBar.module.css";
import { ThemeToggle } from "./ThemeToggle";
import { ViolationsSummary } from "./ViolationsSummary";

interface HeaderBarProps {
  season: Season;
  pool: Candidate[];
  violations: Violation[];
}

export function HeaderBar({ season, pool, violations }: HeaderBarProps) {
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
        <ViolationsSummary violations={violations} pool={pool} />
        <ThemeToggle />
      </div>
    </header>
  );
}
