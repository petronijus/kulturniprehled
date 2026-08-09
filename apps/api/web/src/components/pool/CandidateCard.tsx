import { useDraggable } from "@dnd-kit/core";
import type { Candidate } from "../../api/types";
import { candidateDate } from "../../domain/planState";
import { isoToLocalTime, weekday } from "../../domain/season";
import { cs } from "../../i18n/cs";
import { isNew } from "../../state/newSince";
import styles from "./CandidateCard.module.css";
import { LaneBadge } from "./LaneBadge";

interface CandidateCardProps {
  candidate: Candidate;
  onSelect: () => void;
  onReject: () => void;
  onUndecide: () => void;
  actionsDisabled: boolean;
}

function formatDate(candidate: Candidate): string {
  const date = candidateDate(candidate);
  const dayName = cs.weekdaysShort[weekday(date) - 1] ?? "";
  const [, month, day] = date.split("-");
  return `${dayName} ${Number(day)}. ${Number(month)}. · ${isoToLocalTime(candidate.starts_at)}`;
}

export function CandidateCard({
  candidate,
  onSelect,
  onReject,
  onUndecide,
  actionsDisabled,
}: CandidateCardProps) {
  const draggable = candidate.plan_status !== "selected" && !actionsDisabled;
  const { attributes, listeners, setNodeRef, isDragging } = useDraggable({
    id: `card-${candidate.id}`,
    data: { kind: "card", candidate },
    disabled: !draggable,
  });

  const classes = [styles.card];
  if (candidate.plan_status === "rejected") {
    classes.push(styles.rejected);
  }
  if (candidate.plan_status === "selected") {
    classes.push(styles.selected);
  }
  if (isDragging) {
    classes.push(styles.dragging);
  }

  const program = (candidate.program ?? [])
    .map((entry) => {
      const author = entry.composer ?? entry.author ?? entry.director;
      const work = entry.work ?? entry.play ?? entry.film;
      return typeof author === "string" && typeof work === "string" ? `${author}: ${work}` : null;
    })
    .filter((line): line is string => line !== null);

  return (
    <article ref={setNodeRef} className={classes.join(" ")} {...listeners} {...attributes}>
      <header className={styles.header}>
        <LaneBadge lane={candidate.lane} />
        {candidate.season_event && (
          <span className={styles.seasonBadge}>★ {cs.seasonEventBadge}</span>
        )}
        {isNew(candidate.first_seen_at) && <span className={styles.newBadge}>{cs.newBadge}</span>}
        {candidate.score !== null && (
          <span className={styles.score} title={candidate.why_cs ?? ""}>
            {Math.round(candidate.score * 100)}
          </span>
        )}
      </header>
      <h3 className={styles.title}>{candidate.title}</h3>
      <p className={styles.meta}>
        {formatDate(candidate)}
        {candidate.venue !== null && ` · ${candidate.venue}`}
        {candidate.price_czk !== null && ` · ${candidate.price_czk} Kč`}
      </p>
      {program.length > 0 && <p className={styles.program}>{program.join(" · ")}</p>}
      {candidate.why_cs !== null && <p className={styles.why}>{candidate.why_cs}</p>}
      {candidate.tickets_available === false && <p className={styles.soldOut}>⚠ {cs.soldOut}</p>}
      <footer className={styles.actions}>
        {candidate.plan_status !== "selected" && (
          <button
            type="button"
            className={styles.selectButton}
            onClick={onSelect}
            disabled={actionsDisabled}
          >
            ✓ {cs.select}
          </button>
        )}
        {candidate.plan_status === "undecided" && (
          <button
            type="button"
            className={styles.rejectButton}
            onClick={onReject}
            disabled={actionsDisabled}
          >
            ✕ {cs.reject}
          </button>
        )}
        {candidate.plan_status !== "undecided" && (
          <button
            type="button"
            className={styles.undecideButton}
            onClick={onUndecide}
            disabled={actionsDisabled}
          >
            ↩ {cs.undecide}
          </button>
        )}
        {candidate.url !== null && (
          <a
            className={styles.link}
            href={candidate.url}
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
