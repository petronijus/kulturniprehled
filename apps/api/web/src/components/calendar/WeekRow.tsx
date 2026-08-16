import type { BookedEvent, CalendarEntry, Candidate } from "../../api/types";
import type { IsoDate, MonthGridWeek } from "../../domain/season";
import { isoWeek, monthOf } from "../../domain/season";
import { DayCell } from "./DayCell";
import styles from "./WeekRow.module.css";

const WEEK_CAP = 2;

interface WeekRowProps {
  week: MonthGridWeek;
  month: string;
  today: IsoDate;
  blockedDays: ReadonlySet<IsoDate>;
  dragTargetDate: IsoDate | null;
  plannedByDate: ReadonlyMap<IsoDate, Candidate[]>;
  bookedByDate: ReadonlyMap<IsoDate, BookedEvent[]>;
  personalByDate: ReadonlyMap<IsoDate, CalendarEntry[]>;
  holidaysByDate: ReadonlyMap<IsoDate, string>;
  /** Plan-wide events per ISO week (selected + booked) for the budget dots. */
  weekLoad: ReadonlyMap<string, number>;
  diffOf: (candidateId: string) => "none" | "added" | "removed";
  violatedIds: ReadonlySet<string>;
  previewMode: boolean;
  highlightIds: ReadonlySet<string>;
  highlightDates: ReadonlySet<IsoDate>;
}

export function WeekRow({
  week,
  month,
  today,
  blockedDays,
  dragTargetDate,
  plannedByDate,
  bookedByDate,
  personalByDate,
  holidaysByDate,
  weekLoad,
  diffOf,
  violatedIds,
  previewMode,
  highlightIds,
  highlightDates,
}: WeekRowProps) {
  const weekId = isoWeek(week.start);
  const load = weekLoad.get(weekId) ?? 0;
  const over = load > WEEK_CAP;
  const dots = Array.from({ length: Math.max(load, WEEK_CAP) }, (_, i) => i < load);

  return (
    <div className={styles.row}>
      <div
        className={`${styles.gutter} ${over ? styles.gutterOver : ""}`}
        title={`${weekId}: ${load}/${WEEK_CAP}`}
      >
        {dots.map((filled, i) => (
          <span
            // biome-ignore lint/suspicious/noArrayIndexKey: dots are positional by nature
            key={i}
            className={`${styles.dot} ${filled ? styles.dotFilled : ""}`}
          />
        ))}
      </div>
      {week.days.map((date) => (
        <DayCell
          key={date}
          date={date}
          inMonth={monthOf(date) === month}
          today={date === today}
          blocked={blockedDays.has(date)}
          dragTargetDate={dragTargetDate}
          planned={plannedByDate.get(date) ?? []}
          booked={bookedByDate.get(date) ?? []}
          personal={personalByDate.get(date) ?? []}
          holiday={holidaysByDate.get(date) ?? null}
          diffOf={diffOf}
          violatedIds={violatedIds}
          previewMode={previewMode}
          highlighted={highlightDates.has(date)}
          highlightIds={highlightIds}
        />
      ))}
    </div>
  );
}
