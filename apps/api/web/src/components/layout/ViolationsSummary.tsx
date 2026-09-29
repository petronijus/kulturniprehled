import { useState } from "react";
import type { Candidate } from "../../api/types";
import type { Violation } from "../../domain/violations";
import { en } from "../../i18n/en";
import styles from "./ViolationsSummary.module.css";

interface ViolationsSummaryProps {
  violations: Violation[];
  pool: Candidate[];
}

function describe(violation: Violation, titleOf: (id: string) => string): string {
  switch (violation.kind) {
    case "week_over":
      return en.violations.weekOver(violation.week, violation.count);
    case "gap":
      return en.violations.gap(violation.aTitle, violation.bTitle);
    case "duplicate_work": {
      const first = violation.itemIds[0];
      return en.violations.duplicateWork(first !== undefined ? titleOf(first) : violation.work);
    }
    case "blocked_day":
      return en.violations.blockedDay(violation.title, violation.day);
  }
}

export function ViolationsSummary({ violations, pool }: ViolationsSummaryProps) {
  const [open, setOpen] = useState(false);
  const titleOf = (id: string) => pool.find((candidate) => candidate.id === id)?.title ?? id;

  if (violations.length === 0) {
    return <span className={styles.clean}>{en.violations.none}</span>;
  }

  return (
    <div className={styles.wrapper}>
      <button
        type="button"
        className={styles.badge}
        aria-expanded={open}
        onClick={() => setOpen((value) => !value)}
      >
        ⚠ {violations.length}
      </button>
      {open && (
        <div className={styles.popover}>
          <p className={styles.popoverTitle}>{en.violations.title}</p>
          <ul className={styles.list}>
            {violations.map((violation, index) => (
              // biome-ignore lint/suspicious/noArrayIndexKey: list is derived, order-stable per render
              <li key={index}>{describe(violation, titleOf)}</li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
