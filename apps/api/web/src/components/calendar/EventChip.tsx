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
  /** Open this concert's card in the pool. */
  onOpen: (candidate: Candidate) => void;
}

/** A selected candidate on its calendar day. Click opens its pool card,
 * dragging it out of the calendar deselects it.
 *
 * Both gestures live on one element because the pointer sensor only starts a
 * drag after 6px of travel (see PlannerDnd) — under that it is a click, and
 * the chip was previously swallowing it with nothing on the other side. */
export function EventChip({
  candidate,
  diff,
  violated,
  dragDisabled,
  highlighted,
  onOpen,
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
    <button
      type="button"
      ref={setNodeRef}
      className={`${classes.join(" ")} ${styles.clickable}`}
      style={{ borderInlineStartColor: `var(--lane-${candidate.lane})` }}
      title={candidate.why_cs ?? candidate.title}
      aria-label={`${cs.calendar.openCard}: ${candidate.title}`}
      onClick={() => onOpen(candidate)}
      {...listeners}
      {...attributes}
    >
      <span className={styles.time}>{isoToLocalTime(candidate.starts_at)}</span>
      <span className={styles.title}>{candidate.title}</span>
      {candidate.season_event && <span className={styles.season}>★</span>}
    </button>
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
