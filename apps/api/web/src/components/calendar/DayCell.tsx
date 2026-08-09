import { useDroppable } from "@dnd-kit/core";
import type { BookedEvent, Candidate } from "../../api/types";
import type { IsoDate } from "../../domain/season";
import styles from "./DayCell.module.css";
import { BookedChip, EventChip } from "./EventChip";

interface DayCellProps {
  date: IsoDate;
  inMonth: boolean;
  today: boolean;
  blocked: boolean;
  /** The dragged candidate's own date — the only valid drop target. */
  dragTargetDate: IsoDate | null;
  planned: Candidate[];
  booked: BookedEvent[];
  diffOf: (candidateId: string) => "none" | "added" | "removed";
  violatedIds: ReadonlySet<string>;
  previewMode: boolean;
  /** Pool-card hover/pin: this cell holds a highlighted candidate's date. */
  highlighted: boolean;
  highlightIds: ReadonlySet<string>;
}

export function DayCell({
  date,
  inMonth,
  today,
  blocked,
  dragTargetDate,
  planned,
  booked,
  diffOf,
  violatedIds,
  previewMode,
  highlighted,
  highlightIds,
}: DayCellProps) {
  const isTarget = dragTargetDate === date;
  const { setNodeRef, isOver } = useDroppable({
    id: `day-${date}`,
    data: { kind: "day", date },
    disabled: !isTarget,
  });

  const classes = [styles.cell];
  if (!inMonth) {
    classes.push(styles.outside);
  }
  if (today) {
    classes.push(styles.today);
  }
  if (blocked) {
    classes.push(styles.blocked);
  }
  if (isTarget) {
    classes.push(styles.target);
  }
  if (isTarget && isOver) {
    classes.push(styles.over);
  }
  if (highlighted) {
    classes.push(styles.highlighted);
  }

  return (
    <div ref={setNodeRef} className={classes.join(" ")} data-date={date}>
      <span className={styles.dayNumber}>{Number(date.slice(8, 10))}</span>
      <div className={styles.chips}>
        {booked.map((event) => (
          <BookedChip key={event.id} title={event.title} />
        ))}
        {planned.map((candidate) => (
          <EventChip
            key={candidate.id}
            candidate={candidate}
            diff={diffOf(candidate.id)}
            violated={violatedIds.has(candidate.id)}
            dragDisabled={previewMode}
            highlighted={highlightIds.has(candidate.id)}
          />
        ))}
      </div>
    </div>
  );
}
