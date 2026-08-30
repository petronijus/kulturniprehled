import { useDroppable } from "@dnd-kit/core";
import { useMemo, useState } from "react";
import type { BookedEvent, Candidate, PlanStatus, ProgramMediaLink } from "../../api/types";
import { decodeFacet, matchesFacet, poolFacets } from "../../domain/facets";
import { candidateDate } from "../../domain/planState";
import type { ProductionGroup } from "../../domain/productions";
import { groupStatus, isProductionBooked } from "../../domain/productions";
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
  groups: ProductionGroup[];
  booked: BookedEvent[];
  months: IsoMonth[];
  programLinks: ReadonlyMap<string, ProgramMediaLink>;
  onSetStatus: (candidate: Candidate, status: PlanStatus) => void;
  onHoverChange: (group: ProductionGroup | null) => void;
  pinnedKeys: ReadonlySet<string>;
  onTogglePin: (group: ProductionGroup) => void;
  actionsDisabled: boolean;
}

export function CandidatePool({
  pool,
  groups,
  booked,
  months,
  programLinks,
  onSetStatus,
  onHoverChange,
  pinnedKeys,
  onTogglePin,
  actionsDisabled,
}: CandidatePoolProps) {
  const [filters, setFilters] = useState<PoolFilterState>(defaultFilters);
  const facets = useMemo(() => poolFacets(pool), [pool]);
  const { setNodeRef, isOver } = useDroppable({ id: "pool", data: { kind: "pool" } });

  // Filters apply at production level: a group passes when ANY of its dates
  // does, so a month filter shows every production reaching into that month.
  const visible = useMemo(() => {
    const query = filters.query.trim().toLowerCase();
    const facet = filters.facet === null ? null : decodeFacet(filters.facet);
    return groups
      .filter((group) => {
        if (isProductionBooked(group, booked)) {
          return false;
        }
        const status = groupStatus(group);
        if (!filters.showRejected && status === "rejected") {
          return false;
        }
        if (filters.undecidedOnly && status !== "undecided") {
          return false;
        }
        return group.candidates.some((candidate) => {
          if (filters.lane !== null && candidate.lane !== filters.lane) {
            return false;
          }
          if (filters.month !== null && monthOf(candidateDate(candidate)) !== filters.month) {
            return false;
          }
          if (filters.newOnly && !isNew(candidate.first_seen_at)) {
            return false;
          }
          if (facet !== null && !matchesFacet(candidate, facet)) {
            return false;
          }
          if (query !== "") {
            const haystack =
              `${candidate.title} ${candidate.venue ?? ""} ${candidate.source_name ?? ""}`.toLowerCase();
            if (!haystack.includes(query)) {
              return false;
            }
          }
          return true;
        });
      })
      .sort((a, b) => {
        // Chronological and stable: selecting a date must not move the card.
        // Only rejected productions (visible via the toggle) sink to the end.
        const rejectedDelta =
          Number(groupStatus(a) === "rejected") - Number(groupStatus(b) === "rejected");
        if (rejectedDelta !== 0) {
          return rejectedDelta;
        }
        const firstA = a.candidates[0]?.starts_at ?? "";
        const firstB = b.candidates[0]?.starts_at ?? "";
        return firstA.localeCompare(firstB);
      });
  }, [groups, booked, filters]);

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
      <PoolFilters filters={filters} months={months} facets={facets} onChange={setFilters} />
      <div className={styles.cards}>
        {visible.length === 0 && <p className={styles.empty}>{cs.poolEmpty}</p>}
        {visible.map((group) => (
          <CandidateCard
            key={group.key}
            group={group}
            programLinks={programLinks}
            onSetStatus={onSetStatus}
            onHoverChange={onHoverChange}
            pinned={pinnedKeys.has(group.key)}
            onTogglePin={() => onTogglePin(group)}
            actionsDisabled={actionsDisabled}
          />
        ))}
      </div>
    </div>
  );
}
