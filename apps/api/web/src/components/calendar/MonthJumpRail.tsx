import type { IsoMonth } from "../../domain/season";
import { en } from "../../i18n/en";
import styles from "./MonthJumpRail.module.css";

interface MonthJumpRailProps {
  months: IsoMonth[];
  activeMonth: IsoMonth | null;
  onJump: (month: IsoMonth) => void;
}

export function MonthJumpRail({ months, activeMonth, onJump }: MonthJumpRailProps) {
  return (
    <nav className={styles.rail} aria-label={en.monthsLabel}>
      {months.map((month) => {
        const index = Number(month.slice(5)) - 1;
        return (
          <button
            key={month}
            type="button"
            className={`${styles.stop} ${month === activeMonth ? styles.active : ""}`}
            onClick={() => onJump(month)}
          >
            {en.monthsShort[index] ?? month}
          </button>
        );
      })}
    </nav>
  );
}
