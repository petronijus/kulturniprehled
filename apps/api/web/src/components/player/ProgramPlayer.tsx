/** The programme, playing — in a panel beside the planner.
 *
 * The running order is handed to Spotify as one list of track URIs, so
 * movements and pieces follow each other without this component timing
 * anything; it only follows what the device reports back. Playback itself
 * happens in `/app/player.html`, which owns a Web Playback SDK device of
 * our own (see `player/protocol.ts` for why it is a separate document).
 */

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { QueueItem } from "../../domain/playQueue";
import { buildSegments } from "../../domain/playQueue";
import { cs } from "../../i18n/cs";
import type { PlayerCommand } from "../../player/protocol";
import { asPlayerEvent } from "../../player/protocol";
import styles from "./ProgramPlayer.module.css";

interface ProgramPlayerProps {
  queue: QueueItem[];
  onClose: () => void;
}

interface TrackState {
  name: string;
  artists: string;
  coverUrl: string | null;
  position: number;
  duration: number;
  reportedAt: number;
}

function clock(ms: number): string {
  const total = Math.max(0, Math.round(ms / 1000));
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
}

const FRAME_SRC = `${import.meta.env.BASE_URL}player.html`;

export function ProgramPlayer({ queue, onClose }: ProgramPlayerProps) {
  const [itemIndex, setItemIndex] = useState(0);
  const [movement, setMovement] = useState(0);
  const [paused, setPaused] = useState(true);
  const [failure, setFailure] = useState<string | null>(null);
  // What the device is actually playing, and since when — the SDK reports
  // only on change, so the playhead is interpolated between reports.
  const [track, setTrack] = useState<TrackState | null>(null);
  const [now, setNow] = useState(() => Date.now());
  // While the slider is being dragged it shows the user's intent, not the
  // device's position; control returns when the device reports the seek.
  const [scrub, setScrub] = useState<number | null>(null);
  const [segmentIndex, setSegmentIndex] = useState(0);
  // Where the device is inside the loaded segment, so ⏭ knows when it has
  // run out of segment and has to load the next one itself.
  const [offset, setOffset] = useState(0);
  const frameRef = useRef<HTMLIFrameElement>(null);
  const lastLoadRef = useRef<PlayerCommand | null>(null);

  const { segments, placeOf, segmentOfItem } = useMemo(() => buildSegments(queue), [queue]);

  const send = useCallback((command: PlayerCommand) => {
    frameRef.current?.contentWindow?.postMessage(command, window.location.origin);
  }, []);

  const startAt = useCallback(
    (index: number) => {
      const at = segmentOfItem.get(index);
      const segment = at === undefined ? undefined : segments[at.segment];
      if (at === undefined || segment === undefined) {
        return;
      }
      setItemIndex(index);
      setMovement(0);
      setSegmentIndex(at.segment);
      setOffset(at.offset);
      const command: PlayerCommand =
        segment.contextUri !== null
          ? { kind: "load", contextUri: segment.contextUri }
          : { kind: "load", uris: segment.uris, offset: at.offset };
      // What the frame replays if it was not listening yet — without this it
      // replayed the top of the queue over whatever had just been picked.
      lastLoadRef.current = command;
      send(command);
    },
    [send, segments, segmentOfItem],
  );

  useEffect(() => {
    const onMessage = (event: MessageEvent) => {
      if (
        event.origin !== window.location.origin ||
        event.source !== frameRef.current?.contentWindow
      ) {
        return;
      }
      const message = asPlayerEvent(event.data);
      if (message === null) {
        return;
      }
      if (message.kind === "failed") {
        setFailure(message.reason);
        return;
      }
      if (message.kind === "hello" || message.kind === "ready") {
        // The frame was not listening when the ▶ was pressed; replay exactly
        // what was asked for, never the top of the queue.
        if (lastLoadRef.current !== null) {
          send(lastLoadRef.current);
        }
        return;
      }
      setPaused(message.isPaused);
      setScrub(null);
      setTrack({
        name: message.trackName,
        artists: message.artists,
        coverUrl: message.coverUrl,
        position: message.position,
        duration: message.duration,
        reportedAt: Date.now(),
      });
      // Resolve the reported track inside the segment that is loaded — the
      // same recording can appear in more than one piece.
      const places = placeOf.get(message.uri) ?? [];
      const at = places.find((place) => place.segment === segmentIndex) ?? places[0];
      if (at !== undefined) {
        setItemIndex(at.item);
        setMovement(at.movement);
        setSegmentIndex(at.segment);
        setOffset(at.offset);
      }
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, [send, placeOf, segmentIndex]);

  // Opening the panel plays the piece the ▶ was pressed on. The frame is
  // almost never listening this early, so this mostly just records the
  // intent; `hello` replays it once the device exists.
  const started = useRef(false);
  useEffect(() => {
    if (started.current || segments.length === 0) {
      return;
    }
    started.current = true;
    startAt(0);
  }, [segments, startAt]);

  useEffect(() => {
    if (paused || track === null) {
      return;
    }
    const timer = window.setInterval(() => setNow(Date.now()), 500);
    return () => window.clearInterval(timer);
  }, [paused, track]);

  const played =
    track === null
      ? 0
      : Math.min(track.position + (paused ? 0 : now - track.reportedAt), track.duration);
  const elapsed = scrub ?? played;

  // The SDK's own ⏭/⏮ move within the loaded segment and stop at its edge.
  // At a boundary the panel has to load the neighbouring segment instead,
  // or the running order simply ends mid-programme.
  const step = (direction: 1 | -1) => {
    const segment = segments[segmentIndex];
    const inside =
      segment !== undefined &&
      segment.contextUri === null &&
      offset + direction >= 0 &&
      offset + direction < segment.uris.length;
    if (inside) {
      send({ kind: direction === 1 ? "next" : "previous" });
      return;
    }
    const neighbour = segments[segmentIndex + direction];
    if (neighbour === undefined) {
      return;
    }
    const item = direction === 1 ? neighbour.items[0] : neighbour.items[neighbour.items.length - 1];
    if (item !== undefined) {
      startAt(item);
    }
  };

  const commitScrub = () => {
    if (scrub !== null) {
      send({ kind: "seek", position: Math.round(scrub) });
    }
  };

  const current = queue[itemIndex];
  if (current === undefined) {
    return null;
  }
  const movements = current.uris.length;

  return (
    <aside className={styles.panel} aria-label={cs.player.title}>
      <header className={styles.header}>
        <h2 className={styles.heading}>{cs.player.title}</h2>
        <button type="button" className={styles.close} onClick={onClose} title={cs.player.close}>
          ✕
        </button>
      </header>

      <p className={styles.now}>
        {current.author !== null && <span className={styles.author}>{current.author}</span>}
        {current.author !== null && current.work !== null && " · "}
        {current.work}
      </p>
      <p className={styles.context}>
        {current.title}
        {movements > 1 && ` · ${cs.player.movement(movement + 1, movements)}`}
        {current.kind === "album" && ` · ${cs.player.wholeAlbum}`}
      </p>

      {track !== null && (
        <div className={styles.nowPlaying}>
          {track.coverUrl !== null && (
            <img className={styles.cover} src={track.coverUrl} alt="" width={56} height={56} />
          )}
          <div className={styles.recording}>
            <span className={styles.trackName}>{track.name}</span>
            <span className={styles.artists}>{track.artists}</span>
            <input
              type="range"
              className={styles.seek}
              min={0}
              max={Math.max(track.duration, 1)}
              step={1000}
              value={elapsed}
              aria-label={cs.player.seek}
              aria-valuetext={`${clock(elapsed)} / ${clock(track.duration)}`}
              onChange={(event) => setScrub(Number(event.target.value))}
              onPointerUp={commitScrub}
              onKeyUp={commitScrub}
              onBlur={commitScrub}
            />
            <span className={styles.times}>
              {clock(elapsed)} / {clock(track.duration)}
            </span>
          </div>
        </div>
      )}

      <iframe
        ref={frameRef}
        className={styles.embed}
        src={FRAME_SRC}
        title={cs.player.title}
        allow="autoplay 'src' https://sdk.scdn.co; encrypted-media 'src' https://sdk.scdn.co"
      />
      {failure !== null && (
        <p className={styles.failed} title={failure}>
          {cs.player.failed}
        </p>
      )}

      <div className={styles.controls}>
        <button
          type="button"
          className={styles.control}
          onClick={() => send({ kind: paused ? "play" : "pause" })}
          title={paused ? cs.player.play : cs.player.pause}
        >
          {paused ? "▶" : "⏸"}
        </button>
        <button
          type="button"
          className={styles.control}
          onClick={() => step(-1)}
          title={cs.player.previous}
        >
          ⏮
        </button>
        <button
          type="button"
          className={styles.control}
          onClick={() => step(1)}
          title={cs.player.next}
        >
          ⏭
        </button>
        {current.spotifyUrl !== null && (
          <a className={styles.openLink} href={current.spotifyUrl} target="_blank" rel="noreferrer">
            {cs.player.openInSpotify}
          </a>
        )}
      </div>

      <ol className={styles.queue}>
        {queue.map((item, index) => (
          <li key={item.key}>
            <button
              type="button"
              className={`${styles.queueItem} ${index === itemIndex ? styles.queueCurrent : ""}`}
              onClick={() => startAt(index)}
            >
              <span className={styles.queueWork}>{item.work ?? item.author}</span>
              {item.author !== null && item.work !== null && (
                <span className={styles.queueAuthor}>{item.author}</span>
              )}
            </button>
          </li>
        ))}
      </ol>
    </aside>
  );
}
