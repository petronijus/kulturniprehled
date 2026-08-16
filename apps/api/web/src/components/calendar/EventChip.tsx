import { useDraggable } from "@dnd-kit/core";
import type { CalendarEntry, Candidate } from "../../api/types";
import { entryLabel } from "../../domain/calendar";
import { isoToLocalTime } from "../../domain/season";
import { cs } from "../../i18n/cs";
import styles from "./EventChip.module.css";

interface EventChipProps {
  candidate: Candidate;
  /** Diff treatment during scenario preview. */
  diff: "none" | "added" | "removed";
  violated: boolean;
  dragDisabled: boolean;
  highlighted: boolean;
}

/** A selected candidate on its calendar day. Draggable out to deselect. */
export function EventChip({
  candidate,
  diff,
  violated,
  dragDisabled,
  highlighted,
}: EventChipProps) {
  const { attributes, listeners, setNodeRef, isDragging } = useDraggable({
    id: `chip-${candidate.id}`,
    data: { kind: "chip", candidate },
    disabled: dragDisabled,
  });

  const classes = [styles.chip];
  if (diff === "added") {
    classes.push(styles.added);
  }
  if (diff === "removed") {
    classes.push(styles.removed);
  }
  if (violated) {
    classes.push(styles.violated);
  }
  if (isDragging) {
    classes.push(styles.dragging);
  }
  if (highlighted) {
    classes.push(styles.highlighted);
  }

  return (
    <div
      ref={setNodeRef}
      className={classes.join(" ")}
      style={{ borderInlineStartColor: `var(--lane-${candidate.lane})` }}
      title={candidate.why_cs ?? candidate.title}
      {...listeners}
      {...attributes}
    >
      <span className={styles.time}>{isoToLocalTime(candidate.starts_at)}</span>
      <span className={styles.title}>{candidate.title}</span>
      {candidate.season_event && <span className={styles.season}>★</span>}
    </div>
  );
}

/** Immutable chip for an already-booked KP event. */
export function BookedChip({ title }: { title: string }) {
  return (
    <div className={`${styles.chip} ${styles.booked}`} title={`${cs.bookedEvent}: ${title}`}>
      <span className={styles.title}>{title}</span>
    </div>
  );
}

/** An entry of the shared household calendar — context, never a plan item.
 * A blocking one (all-day, or the household is away) reads stronger than a
 * mere evening appointment. */
export function PersonalChip({ entry }: { entry: CalendarEntry }) {
  const classes = [styles.chip, styles.personal];
  if (entry.blocking) {
    classes.push(styles.personalBlocking);
  }
  return (
    <div className={classes.join(" ")} title={`${cs.calendar.chipPrefix}: ${entryLabel(entry)}`}>
      <span className={styles.title}>{entryLabel(entry)}</span>
    </div>
  );
}

/** Reserved-slot placeholder from the previewed/applied scenario. */
export function ReservedChip({ lane, note }: { lane: string; note: string | null }) {
  return (
    <div
      className={`${styles.chip} ${styles.reserved}`}
      style={{ borderInlineStartColor: `var(--lane-${lane})` }}
      title={note ?? cs.reservedSlot}
    >
      <span className={styles.title}>{cs.reservedSlot}</span>
    </div>
  );
}
