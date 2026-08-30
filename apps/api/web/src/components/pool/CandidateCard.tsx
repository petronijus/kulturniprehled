import { useDraggable } from "@dnd-kit/core";
import type { Candidate, PlanStatus } from "../../api/types";
import { candidateDate } from "../../domain/planState";
import type { ProductionGroup } from "../../domain/productions";
import { groupStatus } from "../../domain/productions";
import { programLines } from "../../domain/program";
import { isoToLocalTime, weekday } from "../../domain/season";
import { cs } from "../../i18n/cs";
import { isNew } from "../../state/newSince";
import styles from "./CandidateCard.module.css";
import { LaneBadge } from "./LaneBadge";
import { SourceBadge } from "./SourceBadge";

interface CandidateCardProps {
  group: ProductionGroup;
  onSetStatus: (candidate: Candidate, status: PlanStatus) => void;
  onHoverChange: (group: ProductionGroup | null) => void;
  pinned: boolean;
  onTogglePin: () => void;
  actionsDisabled: boolean;
}

function formatDate(candidate: Candidate): string {
  const date = candidateDate(candidate);
  const dayName = cs.weekdaysShort[weekday(date) - 1] ?? "";
  const [, month, day] = date.split("-");
  return `${dayName} ${Number(day)}. ${Number(month)}. · ${isoToLocalTime(candidate.starts_at)}`;
}

/** One date of a multi-date production — click toggles it in/out of the plan. */
function DateRow({
  candidate,
  onSetStatus,
  disabled,
}: {
  candidate: Candidate;
  onSetStatus: (candidate: Candidate, status: PlanStatus) => void;
  disabled: boolean;
}) {
  const selected = candidate.plan_status === "selected";
  const rejected = candidate.plan_status === "rejected";
  const classes = [styles.dateRow];
  if (selected) {
    classes.push(styles.dateSelected);
  }
  if (rejected) {
    classes.push(styles.dateRejected);
  }
  const title = rejected
    ? cs.production.dateRejected
    : selected
      ? cs.production.deselectDate
      : cs.production.selectDate;
  return (
    <button
      type="button"
      className={classes.join(" ")}
      title={title}
      disabled={disabled}
      onClick={() => onSetStatus(candidate, selected ? "undecided" : "selected")}
    >
      <span className={styles.dateLabel}>{formatDate(candidate)}</span>
      {candidate.tickets_available === false && <span className={styles.dateSoldOut}>⚠</span>}
      {selected && <span className={styles.dateMark}>✓ {cs.production.inPlan}</span>}
    </button>
  );
}

export function CandidateCard({
  group,
  onSetStatus,
  onHoverChange,
  pinned,
  onTogglePin,
  actionsDisabled,
}: CandidateCardProps) {
  const { primary, richest, candidates } = group;
  const multiDate = candidates.length > 1;
  const status = groupStatus(group);

  const draggable = status !== "selected" && !actionsDisabled;
  const { attributes, listeners, setNodeRef, isDragging } = useDraggable({
    id: `card-${primary.id}`,
    data: { kind: "card", candidate: primary },
    disabled: !draggable,
  });

  const classes = [styles.card];
  if (status === "rejected") {
    classes.push(styles.rejected);
  }
  if (status === "selected") {
    classes.push(styles.selected);
  }
  if (isDragging) {
    classes.push(styles.dragging);
  }
  if (pinned) {
    classes.push(styles.pinned);
  }

  const program = programLines(richest.program);

  const anyNew = candidates.some((candidate) => isNew(candidate.first_seen_at));
  const seasonEvent = candidates.some((candidate) => candidate.season_event);
  const rejectAll = () => {
    for (const candidate of candidates) {
      if (candidate.plan_status !== "rejected") {
        onSetStatus(candidate, "rejected");
      }
    }
  };
  const undecideAll = () => {
    for (const candidate of candidates) {
      if (candidate.plan_status !== "undecided") {
        onSetStatus(candidate, "undecided");
      }
    }
  };

  return (
    <article
      ref={setNodeRef}
      className={classes.join(" ")}
      onMouseEnter={() => onHoverChange(group)}
      onMouseLeave={() => onHoverChange(null)}
      onFocus={() => onHoverChange(group)}
      onBlur={() => onHoverChange(null)}
      onClick={(event) => {
        // Buttons and links inside the card keep their own actions.
        if ((event.target as HTMLElement).closest("button, a") === null) {
          onTogglePin();
        }
      }}
      onKeyDown={(event) => {
        if (event.key === "Enter" && event.target === event.currentTarget) {
          onTogglePin();
        }
      }}
      {...listeners}
      {...attributes}
    >
      <header className={styles.header}>
        <LaneBadge lane={primary.lane} />
        <SourceBadge sourceType={richest.source_type} sourceName={richest.source_name} />
        {seasonEvent && <span className={styles.seasonBadge}>★ {cs.seasonEventBadge}</span>}
        {anyNew && <span className={styles.newBadge}>{cs.newBadge}</span>}
        {richest.score !== null && (
          <span className={styles.score} title={richest.why_cs ?? ""}>
            {Math.round(richest.score * 100)}
          </span>
        )}
      </header>
      <h3 className={styles.title}>{richest.title}</h3>
      <p className={styles.meta}>
        {multiDate ? cs.production.dates(candidates.length) : formatDate(primary)}
        {primary.venue !== null && ` · ${primary.venue}`}
        {richest.price_czk !== null && ` · ${richest.price_czk} Kč`}
      </p>
      {multiDate && (
        <div className={styles.dates}>
          {candidates.map((candidate) => (
            <DateRow
              key={candidate.id}
              candidate={candidate}
              onSetStatus={onSetStatus}
              disabled={actionsDisabled}
            />
          ))}
        </div>
      )}
      {program.length > 0 && (
        <ul className={styles.program}>
          {program.map((line, index) => (
            // biome-ignore lint/suspicious/noArrayIndexKey: a programme is an ordered list, position is its identity
            <li key={index} className={styles.programLine}>
              {line.author !== null && <span className={styles.programAuthor}>{line.author}</span>}
              {line.author !== null && line.work !== null && (
                <span className={styles.programSeparator} aria-hidden="true">
                  ·
                </span>
              )}
              {line.work !== null && <span className={styles.programWork}>{line.work}</span>}
            </li>
          ))}
        </ul>
      )}
      {richest.why_cs !== null && <p className={styles.why}>{richest.why_cs}</p>}
      {!multiDate && primary.tickets_available === false && (
        <p className={styles.soldOut}>⚠ {cs.soldOut}</p>
      )}
      <footer className={styles.actions}>
        {!multiDate && status !== "selected" && (
          <button
            type="button"
            className={styles.selectButton}
            onClick={() => onSetStatus(primary, "selected")}
            disabled={actionsDisabled}
          >
            ✓ {cs.select}
          </button>
        )}
        {status === "undecided" && (
          <button
            type="button"
            className={styles.rejectButton}
            onClick={rejectAll}
            disabled={actionsDisabled}
          >
            ✕ {cs.reject}
          </button>
        )}
        {status !== "undecided" && (
          <button
            type="button"
            className={styles.undecideButton}
            onClick={undecideAll}
            disabled={actionsDisabled}
          >
            ↩ {cs.undecide}
          </button>
        )}
        {richest.url !== null && (
          <a
            className={styles.link}
            href={richest.url}
            target="_blank"
            rel="noreferrer"
            onPointerDown={(event) => event.stopPropagation()}
          >
            Detail →
          </a>
        )}
      </footer>
    </article>
  );
}
