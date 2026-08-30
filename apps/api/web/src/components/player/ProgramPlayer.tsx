/** The programme, playing — in a panel beside the planner.
 *
 * A concert's programme is a running order, so this is a queue, not a link:
 * one movement follows the next, one work follows the previous, and the
 * panel stays put while Petr keeps planning.
 *
 * Playback itself lives in `/app/player.html` (see `player/protocol.ts`):
 * Spotify's embed API needs `'unsafe-eval'`, and that stays confined to a
 * frame holding nothing but the embed. This component talks to it over
 * postMessage. Advancing is driven by playback updates, because the embed
 * has no "ended" event: a track that has reached its duration hands over.
 */

import { useCallback, useEffect, useRef, useState } from "react";
import type { QueueItem } from "../../domain/playQueue";
import { cs } from "../../i18n/cs";
import type { PlayerCommand } from "../../player/protocol";
import { asPlayerEvent } from "../../player/protocol";
import styles from "./ProgramPlayer.module.css";

interface ProgramPlayerProps {
  queue: QueueItem[];
  onClose: () => void;
}

/** How close to the end counts as finished — the embed's last update never
 * lands exactly on the duration. */
const END_SLACK_MS = 900;

const FRAME_SRC = `${import.meta.env.BASE_URL}player.html`;

interface Position {
  item: number;
  movement: number;
}

export function ProgramPlayer({ queue, onClose }: ProgramPlayerProps) {
  const [position, setPosition] = useState<Position>({ item: 0, movement: 0 });
  const [paused, setPaused] = useState(true);
  const [failed, setFailed] = useState(false);
  const frameRef = useRef<HTMLIFrameElement>(null);
  // The frame answers `ready` once its controller exists; until then a load
  // would be shouted into the void, so the wanted URI waits here.
  const readyRef = useRef(false);
  const wantedUriRef = useRef<string | null>(null);
  const advanceRef = useRef<() => void>(() => {});

  const current = queue[position.item];
  const uri = current?.uris[position.movement] ?? null;

  const send = useCallback((command: PlayerCommand) => {
    frameRef.current?.contentWindow?.postMessage(command, window.location.origin);
  }, []);

  const advance = useCallback(() => {
    setPosition((at) => {
      const item = queue[at.item];
      if (item !== undefined && at.movement + 1 < item.uris.length) {
        return { item: at.item, movement: at.movement + 1 };
      }
      if (at.item + 1 < queue.length) {
        return { item: at.item + 1, movement: 0 };
      }
      return at;
    });
  }, [queue]);

  useEffect(() => {
    advanceRef.current = advance;
  }, [advance]);

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
        setFailed(true);
        return;
      }
      if (message.kind === "hello") {
        readyRef.current = true;
        // Whatever the queue is on now was set before the frame could hear
        // us; replay it.
        const uriNow = wantedUriRef.current;
        if (uriNow !== null) {
          send({ kind: "load", uri: uriNow });
        }
        return;
      }
      if (message.kind === "ready") {
        return;
      }
      setPaused(message.isPaused);
      if (message.duration > 0 && message.position >= message.duration - END_SLACK_MS) {
        advanceRef.current();
      }
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, [send]);

  // Every URI change is a load; the frame builds its controller from the
  // first one it receives, so this also starts playback.
  useEffect(() => {
    if (uri === null || wantedUriRef.current === uri) {
      return;
    }
    wantedUriRef.current = uri;
    if (readyRef.current) {
      send({ kind: "load", uri });
    }
  }, [uri, send]);

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
        {movements > 1 && ` · ${cs.player.movement(position.movement + 1, movements)}`}
        {current.kind === "album" && ` · ${cs.player.wholeAlbum}`}
      </p>

      <iframe
        ref={frameRef}
        className={styles.embed}
        src={FRAME_SRC}
        title={cs.player.title}
        allow="autoplay; encrypted-media; clipboard-write"
      />
      {failed && <p className={styles.failed}>{cs.player.failed}</p>}

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
          onClick={() => setPosition({ item: Math.max(position.item - 1, 0), movement: 0 })}
          disabled={position.item === 0 && position.movement === 0}
          title={cs.player.previous}
        >
          ⏮
        </button>
        <button
          type="button"
          className={styles.control}
          onClick={advance}
          disabled={position.item + 1 >= queue.length && position.movement + 1 >= movements}
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
              className={`${styles.queueItem} ${index === position.item ? styles.queueCurrent : ""}`}
              onClick={() => setPosition({ item: index, movement: 0 })}
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
