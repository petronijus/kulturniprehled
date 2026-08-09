import { useEffect, useMemo, useRef, useState } from "react";
import type { BookedEvent, Candidate, ReservedSlot, Season } from "../../api/types";
import { candidateDate } from "../../domain/planState";
import type { IsoDate, IsoMonth } from "../../domain/season";
import { isoToLocalDate, isoWeek, monthOf, monthsBetween } from "../../domain/season";
import type { Violation } from "../../domain/violations";
import { MonthGrid } from "./MonthGrid";
import { MonthJumpRail } from "./MonthJumpRail";
import styles from "./SeasonCalendar.module.css";

interface SeasonCalendarProps {
  season: Season;
  pool: Candidate[];
  booked: BookedEvent[];
  selectedIds: ReadonlySet<string>;
  /** Live-plan selection, used for the diff treatment during preview. */
  planIds: ReadonlySet<string>;
  previewMode: boolean;
  reservedSlots: ReservedSlot[];
  violations: Violation[];
  blockedDays: ReadonlySet<IsoDate>;
  /** The dragged candidate's own date, or null when no drag is active. */
  dragTargetDate: IsoDate | null;
}

export function SeasonCalendar({
  season,
  pool,
  booked,
  selectedIds,
  planIds,
  previewMode,
  reservedSlots,
  violations,
  blockedDays,
  dragTargetDate,
}: SeasonCalendarProps) {
  const months = useMemo(
    () => monthsBetween(season.starts_on, season.ends_on),
    [season.starts_on, season.ends_on],
  );
  const today = isoToLocalDate(new Date().toISOString());
  const scrollRef = useRef<HTMLDivElement>(null);
  const [activeMonth, setActiveMonth] = useState<IsoMonth | null>(months[0] ?? null);

  // Union of preview selection and live plan — removed chips stay visible
  // (struck through) during preview.
  const visibleIds = useMemo(() => {
    const ids = new Set(selectedIds);
    if (previewMode) {
      for (const id of planIds) {
        ids.add(id);
      }
    }
    return ids;
  }, [selectedIds, planIds, previewMode]);

  const plannedByDate = useMemo(() => {
    const byDate = new Map<IsoDate, Candidate[]>();
    for (const candidate of pool) {
      if (!visibleIds.has(candidate.id)) {
        continue;
      }
      const date = candidateDate(candidate);
      const bucket = byDate.get(date);
      if (bucket === undefined) {
        byDate.set(date, [candidate]);
      } else {
        bucket.push(candidate);
      }
    }
    return byDate;
  }, [pool, visibleIds]);

  const bookedByDate = useMemo(() => {
    const byDate = new Map<IsoDate, BookedEvent[]>();
    for (const event of booked) {
      const date = isoToLocalDate(event.starts_at);
      const bucket = byDate.get(date);
      if (bucket === undefined) {
        byDate.set(date, [event]);
      } else {
        bucket.push(event);
      }
    }
    return byDate;
  }, [booked]);

  const weekLoad = useMemo(() => {
    const load = new Map<string, number>();
    const bump = (date: IsoDate) => {
      const week = isoWeek(date);
      load.set(week, (load.get(week) ?? 0) + 1);
    };
    for (const candidate of pool) {
      if (selectedIds.has(candidate.id)) {
        bump(candidateDate(candidate));
      }
    }
    for (const event of booked) {
      bump(isoToLocalDate(event.starts_at));
    }
    return load;
  }, [pool, booked, selectedIds]);

  const violatedIds = useMemo(() => {
    const ids = new Set<string>();
    for (const violation of violations) {
      switch (violation.kind) {
        case "week_over":
        case "duplicate_work":
          for (const id of violation.itemIds) {
            ids.add(id);
          }
          break;
        case "gap":
          ids.add(violation.aId);
          ids.add(violation.bId);
          break;
        case "blocked_day":
          ids.add(violation.itemId);
          break;
      }
    }
    return ids;
  }, [violations]);

  const reservedByMonth = useMemo(() => {
    const byMonth = new Map<IsoMonth, ReservedSlot[]>();
    for (const slot of reservedSlots) {
      const bucket = byMonth.get(slot.month);
      if (bucket === undefined) {
        byMonth.set(slot.month, [slot]);
      } else {
        bucket.push(slot);
      }
    }
    return byMonth;
  }, [reservedSlots]);

  const diffOf = useMemo(() => {
    return (candidateId: string): "none" | "added" | "removed" => {
      if (!previewMode) {
        return "none";
      }
      const inPreview = selectedIds.has(candidateId);
      const inPlan = planIds.has(candidateId);
      if (inPreview && !inPlan) {
        return "added";
      }
      if (!inPreview && inPlan) {
        return "removed";
      }
      return "none";
    };
  }, [previewMode, selectedIds, planIds]);

  // Scrollspy for the jump rail.
  useEffect(() => {
    const container = scrollRef.current;
    if (container === null) {
      return;
    }
    const sections = Array.from(container.querySelectorAll<HTMLElement>("[data-month]"));
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            const month = (entry.target as HTMLElement).dataset["month"];
            if (month !== undefined) {
              setActiveMonth(month);
            }
          }
        }
      },
      { root: container, rootMargin: "0px 0px -70% 0px" },
    );
    for (const section of sections) {
      observer.observe(section);
    }
    return () => observer.disconnect();
  }, []);

  // Auto-scroll to the dragged candidate's month.
  useEffect(() => {
    if (dragTargetDate === null) {
      return;
    }
    const container = scrollRef.current;
    const section = container?.querySelector(`[data-month="${monthOf(dragTargetDate)}"]`);
    section?.scrollIntoView({ behavior: "smooth", block: "start" });
  }, [dragTargetDate]);

  const jumpTo = (month: IsoMonth) => {
    scrollRef.current
      ?.querySelector(`[data-month="${month}"]`)
      ?.scrollIntoView({ behavior: "smooth", block: "start" });
  };

  return (
    <div className={styles.wrapper}>
      <MonthJumpRail months={months} activeMonth={activeMonth} onJump={jumpTo} />
      <div ref={scrollRef} className={styles.scroll}>
        {months.map((month) => (
          <MonthGrid
            key={month}
            month={month}
            today={today}
            blockedDays={blockedDays}
            dragTargetDate={dragTargetDate}
            plannedByDate={plannedByDate}
            bookedByDate={bookedByDate}
            weekLoad={weekLoad}
            reservedSlots={reservedByMonth.get(month) ?? []}
            diffOf={diffOf}
            violatedIds={violatedIds}
            previewMode={previewMode}
          />
        ))}
      </div>
    </div>
  );
}
