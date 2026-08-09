/** DnD wiring. Because candidate dates are fixed, a drag has exactly one
 * valid calendar target — the candidate's own date cell — so dropping is a
 * confirmation gesture, not a positioning problem. The card's ✓/✕ buttons
 * are the full functional (and keyboard-accessible) equivalent. */

import type { DragEndEvent, DragStartEvent } from "@dnd-kit/core";
import {
  DndContext,
  DragOverlay,
  KeyboardSensor,
  PointerSensor,
  useSensor,
  useSensors,
} from "@dnd-kit/core";
import type { ReactNode } from "react";
import { useState } from "react";
import type { Candidate, PlanStatus } from "../../api/types";
import { candidateDate } from "../../domain/planState";
import type { IsoDate } from "../../domain/season";
import styles from "./PlannerDnd.module.css";

interface DragData {
  kind: "card" | "chip";
  candidate: Candidate;
}

interface PlannerDndProps {
  onSetStatus: (candidate: Candidate, status: PlanStatus) => void;
  children: (dragTargetDate: IsoDate | null) => ReactNode;
}

export function PlannerDnd({ onSetStatus, children }: PlannerDndProps) {
  const [active, setActive] = useState<DragData | null>(null);
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 6 } }),
    useSensor(KeyboardSensor),
  );

  const handleDragStart = (event: DragStartEvent) => {
    const data = event.active.data.current as DragData | undefined;
    setActive(data ?? null);
  };

  const handleDragEnd = (event: DragEndEvent) => {
    const data = active;
    setActive(null);
    if (data === undefined || data === null || event.over === null) {
      return;
    }
    const overId = String(event.over.id);
    if (data.kind === "card" && overId === `day-${candidateDate(data.candidate)}`) {
      onSetStatus(data.candidate, "selected");
    } else if (data.kind === "chip" && overId === "pool") {
      onSetStatus(data.candidate, "undecided");
    }
  };

  // Dragging a card highlights its own date; dragging a chip out targets
  // the pool, so no calendar cell lights up.
  const dragTargetDate = active?.kind === "card" ? candidateDate(active.candidate) : null;

  return (
    <DndContext
      sensors={sensors}
      onDragStart={handleDragStart}
      onDragEnd={handleDragEnd}
      onDragCancel={() => setActive(null)}
    >
      {children(dragTargetDate)}
      <DragOverlay>
        {active !== null && (
          <div className={styles.overlay}>
            <span
              className={styles.lane}
              style={{ background: `var(--lane-${active.candidate.lane})` }}
            />
            {active.candidate.title}
          </div>
        )}
      </DragOverlay>
    </DndContext>
  );
}
