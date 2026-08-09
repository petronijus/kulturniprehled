import { useDroppable } from "@dnd-kit/core";
import { useMemo, useState } from "react";
import type { Candidate, PlanStatus } from "../../api/types";
import { candidateDate } from "../../domain/planState";
import type { IsoMonth } from "../../domain/season";
import { monthOf } from "../../domain/season";
import { cs } from "../../i18n/cs";
import { isNew } from "../../state/newSince";
import { CandidateCard } from "./CandidateCard";
import styles from "./CandidatePool.module.css";
import type { PoolFilterState } from "./PoolFilters";
import { defaultFilters, PoolFilters } from "./PoolFilters";

interface CandidatePoolProps {
  pool: Candidate[];
  months: IsoMonth[];
  onSetStatus: (candidate: Candidate, status: PlanStatus) => void;
  onHoverChange: (candidate: Candidate | null) => void;
  pinnedIds: ReadonlySet<string>;
  onTogglePin: (candidate: Candidate) => void;
  actionsDisabled: boolean;
}

const STATUS_ORDER: Record<PlanStatus, number> = { undecided: 0, selected: 1, rejected: 2 };

export function CandidatePool({
  pool,
  months,
  onSetStatus,
  onHoverChange,
  pinnedIds,
  onTogglePin,
  actionsDisabled,
}: CandidatePoolProps) {
  const [filters, setFilters] = useState<PoolFilterState>(defaultFilters);
  const { setNodeRef, isOver } = useDroppable({ id: "pool", data: { kind: "pool" } });

  const visible = useMemo(() => {
    const query = filters.query.trim().toLowerCase();
    return pool
      .filter((candidate) => {
        if (filters.lane !== null && candidate.lane !== filters.lane) {
          return false;
        }
        if (filters.month !== null && monthOf(candidateDate(candidate)) !== filters.month) {
          return false;
        }
        if (filters.undecidedOnly && candidate.plan_status !== "undecided") {
          return false;
        }
        if (filters.newOnly && !isNew(candidate.first_seen_at)) {
          return false;
        }
        if (query !== "" && !candidate.title.toLowerCase().includes(query)) {
          return false;
        }
        return true;
      })
      .sort((a, b) => {
        const statusDelta = STATUS_ORDER[a.plan_status] - STATUS_ORDER[b.plan_status];
        if (statusDelta !== 0) {
          return statusDelta;
        }
        return a.starts_at.localeCompare(b.starts_at);
      });
  }, [pool, filters]);

  if (pool.length === 0) {
    // The season exists but the scrape hasn't filled it yet — explain the
    // one manual step instead of showing a bare "no results".
    return (
      <div className={styles.pool}>
        <div className={styles.scrapeNotice}>
          <h2 className={styles.scrapeTitle}>{cs.emptyPool.title}</h2>
          <p className={styles.scrapeBody}>{cs.emptyPool.body}</p>
          <code className={styles.scrapeCommand}>{cs.emptyPool.command}</code>
          <p className={styles.scrapeHint}>{cs.emptyPool.hint}</p>
        </div>
      </div>
    );
  }

  return (
    <div ref={setNodeRef} className={`${styles.pool} ${isOver ? styles.dropTarget : ""}`}>
      <PoolFilters filters={filters} months={months} onChange={setFilters} />
      <div className={styles.cards}>
        {visible.length === 0 && <p className={styles.empty}>{cs.poolEmpty}</p>}
        {visible.map((candidate) => (
          <CandidateCard
            key={candidate.id}
            candidate={candidate}
            onSelect={() => onSetStatus(candidate, "selected")}
            onReject={() => onSetStatus(candidate, "rejected")}
            onUndecide={() => onSetStatus(candidate, "undecided")}
            onHoverChange={onHoverChange}
            pinned={pinnedIds.has(candidate.id)}
            onTogglePin={() => onTogglePin(candidate)}
            actionsDisabled={actionsDisabled}
          />
        ))}
      </div>
    </div>
  );
}
