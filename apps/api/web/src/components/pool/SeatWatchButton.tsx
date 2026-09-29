/** Watch a sold-out hall from the card it is sold out on.
 *
 * The button is the whole of setting it up: one timer works through every
 * watch that exists, so there is no schedule to configure afterwards. What
 * it does need is the ticketing system's own hall link — that link carries
 * the session which lets the runner read the seat map without a browser, and
 * nothing in the pool knows it, so it gets pasted once here.
 */

import { useState } from "react";
import { useCreateSeatWatch, useDeleteSeatWatch, useUpdateSeatWatch } from "../../api/mutations";
import type { Candidate, SeatWatch } from "../../api/types";
import { en } from "../../i18n/en";
import styles from "./SeatWatchButton.module.css";

interface SeatWatchButtonProps {
  candidate: Candidate;
  watch: SeatWatch | undefined;
  disabled: boolean;
}

// Standing room and wheelchair places are not what "two seats together"
// means; the ids are the ticketing system's price categories.
const NOT_SEATS = ["7328", "7327"];

function when(iso: string | null): string {
  if (iso === null) {
    return en.watch.neverChecked;
  }
  const minutes = Math.round((Date.now() - new Date(iso).getTime()) / 60_000);
  if (minutes < 1) {
    return en.watch.checked(en.watch.justNow);
  }
  if (minutes < 60) {
    return en.watch.checked(en.watch.minutesAgo(minutes));
  }
  return en.watch.checked(en.watch.hoursAgo(Math.round(minutes / 60)));
}

export function SeatWatchButton({ candidate, watch, disabled }: SeatWatchButtonProps) {
  const [open, setOpen] = useState(false);
  const [url, setUrl] = useState("");
  const [seats, setSeats] = useState(2);
  const create = useCreateSeatWatch();
  const update = useUpdateSeatWatch();
  const remove = useDeleteSeatWatch();

  const submit = () => {
    const trimmed = url.trim();
    if (trimmed === "") {
      return;
    }
    create.mutate(
      {
        candidate,
        hallUrl: trimmed,
        minAdjacent: seats,
        excludeCategories: NOT_SEATS,
      },
      {
        onSuccess: () => {
          setOpen(false);
          setUrl("");
        },
      },
    );
  };

  if (watch?.state === "found") {
    const found = watch.found_seats ?? [];
    return (
      <div className={styles.found}>
        <span className={styles.foundText}>🎟 {en.watch.found(found.length)}</span>
        <a className={styles.foundLink} href={watch.hall_url} target="_blank" rel="noreferrer">
          {en.watch.openHall}
        </a>
        <button type="button" className={styles.plain} onClick={() => remove.mutate(watch)}>
          ✕
        </button>
      </div>
    );
  }

  if (watch?.state === "active") {
    const expired = watch.last_error === "content_expired";
    return (
      <div className={styles.active}>
        <span className={styles.status} title={watch.last_error ?? undefined}>
          👁 {en.watch.active}
          <span className={styles.detail}>
            {expired
              ? en.watch.expiredLink
              : watch.last_free_seats !== null && watch.last_free_seats > 0
                ? en.watch.freeSeats(watch.last_free_seats)
                : when(watch.last_checked_at)}
          </span>
        </span>
        {expired && (
          <button type="button" className={styles.plain} onClick={() => setOpen(true)}>
            ↻
          </button>
        )}
        <button
          type="button"
          className={styles.plain}
          onClick={() => update.mutate({ watch, patch: { state: "stopped" } })}
          title={en.watch.stop}
        >
          ✕
        </button>
        {open && (
          <Prompt
            url={url}
            seats={seats}
            onUrl={setUrl}
            onSeats={setSeats}
            onCancel={() => setOpen(false)}
            onSubmit={submit}
            pending={create.isPending}
          />
        )}
      </div>
    );
  }

  return (
    <>
      <button
        type="button"
        className={styles.button}
        onClick={() => setOpen(true)}
        disabled={disabled}
      >
        👁 {watch === undefined ? en.watch.start : en.watch.again}
      </button>
      {open && (
        <Prompt
          url={url}
          seats={seats}
          onUrl={setUrl}
          onSeats={setSeats}
          onCancel={() => setOpen(false)}
          onSubmit={submit}
          pending={create.isPending}
        />
      )}
    </>
  );
}

interface PromptProps {
  url: string;
  seats: number;
  onUrl: (value: string) => void;
  onSeats: (value: number) => void;
  onCancel: () => void;
  onSubmit: () => void;
  pending: boolean;
}

function Prompt({ url, seats, onUrl, onSeats, onCancel, onSubmit, pending }: PromptProps) {
  return (
    <div className={styles.prompt}>
      <label className={styles.label} htmlFor="watch-url">
        {en.watch.prompt}
      </label>
      <input
        id="watch-url"
        type="url"
        className={styles.input}
        value={url}
        placeholder="https://tickets…/Hall/Index/…"
        onChange={(event) => onUrl(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === "Enter") {
            onSubmit();
          }
          if (event.key === "Escape") {
            onCancel();
          }
        }}
      />
      <p className={styles.hint}>{en.watch.promptHint}</p>
      <div className={styles.row}>
        <label className={styles.label} htmlFor="watch-seats">
          {en.watch.seatsWanted}
        </label>
        <input
          id="watch-seats"
          type="number"
          min={1}
          max={6}
          className={styles.number}
          value={seats}
          onChange={(event) => onSeats(Math.max(1, Math.min(6, Number(event.target.value))))}
        />
        <button type="button" className={styles.confirm} onClick={onSubmit} disabled={pending}>
          👁 {en.watch.start}
        </button>
        <button type="button" className={styles.plain} onClick={onCancel}>
          ✕
        </button>
      </div>
    </div>
  );
}
