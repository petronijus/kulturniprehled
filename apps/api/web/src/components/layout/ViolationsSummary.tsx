import { useState } from "react";
import type { Candidate } from "../../api/types";
import type { Violation } from "../../domain/violations";
import { cs } from "../../i18n/cs";
import styles from "./ViolationsSummary.module.css";

interface ViolationsSummaryProps {
  violations: Violation[];
  pool: Candidate[];
}

function describe(violation: Violation, titleOf: (id: string) => string): string {
  switch (violation.kind) {
    case "week_over":
      return cs.violations.weekOver(violation.week, violation.count);
    case "gap":
      return cs.violations.gap(violation.aTitle, violation.bTitle);
    case "duplicate_work": {
      const first = violation.itemIds[0];
      return cs.violations.duplicateWork(first !== undefined ? titleOf(first) : violation.work);
    }
    case "blocked_day":
      return cs.violations.blockedDay(violation.title, violation.day);
  }
}

export function ViolationsSummary({ violations, pool }: ViolationsSummaryProps) {
  const [open, setOpen] = useState(false);
  const titleOf = (id: string) => pool.find((candidate) => candidate.id === id)?.title ?? id;

  if (violations.length === 0) {
    return <span className={styles.clean}>{cs.violations.none}</span>;
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
          <p className={styles.popoverTitle}>{cs.violations.title}</p>
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
