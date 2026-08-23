import { useDroppable } from "@dnd-kit/core";
import type { BookedEvent, CalendarEntry, Candidate } from "../../api/types";
import { dayTooltip } from "../../domain/calendar";
import type { IsoDate } from "../../domain/season";
import { cs } from "../../i18n/cs";
import styles from "./DayCell.module.css";
import { BookedChip, EventChip, PersonalChip } from "./EventChip";

/** Household entries shown in full; the rest collapse into a "+N" summary so
 * a busy family day can never push the cultural plan out of its cell. */
const MAX_PERSONAL_CHIPS = 2;

interface DayCellProps {
  date: IsoDate;
  inMonth: boolean;
  today: boolean;
  blocked: boolean;
  /** The dragged candidate's own date — the only valid drop target. */
  dragTargetDate: IsoDate | null;
  planned: Candidate[];
  booked: BookedEvent[];
  /** Shared household calendar (Kocourek&Prdelčička) on this day. */
  personal: CalendarEntry[];
  /** Public-holiday name, or null on an ordinary day. */
  holiday: string | null;
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
  personal,
  holiday,
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
  if (booked.length > 0) {
    classes.push(styles.bookedDay);
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
  if (holiday !== null) {
    classes.push(styles.holiday);
  }

  const shownPersonal = personal.slice(0, MAX_PERSONAL_CHIPS);
  const hiddenPersonal = personal.slice(MAX_PERSONAL_CHIPS);

  return (
    <div ref={setNodeRef} className={classes.join(" ")} data-date={date}>
      <span className={styles.dayNumber} title={holiday ?? undefined}>
        {Number(date.slice(8, 10))}
      </span>
      {holiday !== null && (
        <span className={styles.holidayName} title={holiday}>
          {holiday}
        </span>
      )}
      <div className={styles.chips}>
        {shownPersonal.map((entry) => (
          <PersonalChip key={`${entry.uid}-${entry.span_index}`} entry={entry} />
        ))}
        {hiddenPersonal.length > 0 && (
          <span className={styles.personalMore} title={dayTooltip(hiddenPersonal)}>
            {cs.calendar.more(hiddenPersonal.length)}
          </span>
        )}
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
