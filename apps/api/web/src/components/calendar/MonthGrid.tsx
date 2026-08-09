import type { BookedEvent, Candidate, ReservedSlot } from "../../api/types";
import type { IsoDate, IsoMonth } from "../../domain/season";
import { monthGrid } from "../../domain/season";
import { cs } from "../../i18n/cs";
import { ReservedChip } from "./EventChip";
import styles from "./MonthGrid.module.css";
import { WeekRow } from "./WeekRow";

interface MonthGridProps {
  month: IsoMonth;
  today: IsoDate;
  blockedDays: ReadonlySet<IsoDate>;
  dragTargetDate: IsoDate | null;
  plannedByDate: ReadonlyMap<IsoDate, Candidate[]>;
  bookedByDate: ReadonlyMap<IsoDate, BookedEvent[]>;
  weekLoad: ReadonlyMap<string, number>;
  reservedSlots: ReservedSlot[];
  diffOf: (candidateId: string) => "none" | "added" | "removed";
  violatedIds: ReadonlySet<string>;
  previewMode: boolean;
  highlightCandidate: { id: string; date: IsoDate } | null;
}

export function MonthGrid({
  month,
  today,
  blockedDays,
  dragTargetDate,
  plannedByDate,
  bookedByDate,
  weekLoad,
  reservedSlots,
  diffOf,
  violatedIds,
  previewMode,
  highlightCandidate,
}: MonthGridProps) {
  const [yearStr, monthStr] = month.split("-") as [string, string];
  const monthName = cs.months[Number(monthStr) - 1] ?? month;

  return (
    <section className={styles.month} data-month={month}>
      <header className={styles.header}>
        <h2 className={styles.title}>
          {monthName} <span className={styles.year}>{yearStr}</span>
        </h2>
        {reservedSlots.length > 0 && (
          <div className={styles.reserved}>
            {reservedSlots.map((slot) => (
              <ReservedChip
                key={`${slot.lane}-${slot.month}`}
                lane={slot.lane}
                note={slot.note_cs}
              />
            ))}
          </div>
        )}
      </header>
      <div className={styles.weekdays}>
        <span className={styles.gutterSpacer} />
        {cs.weekdaysShort.map((day) => (
          <span key={day} className={styles.weekday}>
            {day}
          </span>
        ))}
      </div>
      <div className={styles.grid}>
        {monthGrid(month).map((week) => (
          <WeekRow
            key={week.start}
            week={week}
            month={month}
            today={today}
            blockedDays={blockedDays}
            dragTargetDate={dragTargetDate}
            plannedByDate={plannedByDate}
            bookedByDate={bookedByDate}
            weekLoad={weekLoad}
            diffOf={diffOf}
            violatedIds={violatedIds}
            previewMode={previewMode}
            highlightCandidate={highlightCandidate}
          />
        ))}
      </div>
    </section>
  );
}
