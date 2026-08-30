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
import { cs } from "../../i18n/cs";
import type { PlayerCommand } from "../../player/protocol";
import { asPlayerEvent } from "../../player/protocol";
import styles from "./ProgramPlayer.module.css";

interface ProgramPlayerProps {
  queue: QueueItem[];
  onClose: () => void;
}

const FRAME_SRC = `${import.meta.env.BASE_URL}player.html`;

export function ProgramPlayer({ queue, onClose }: ProgramPlayerProps) {
  const [itemIndex, setItemIndex] = useState(0);
  const [movement, setMovement] = useState(0);
  const [paused, setPaused] = useState(true);
  const [failure, setFailure] = useState<string | null>(null);
  const frameRef = useRef<HTMLIFrameElement>(null);
  const readyRef = useRef(false);

  // One flat running order, plus a way back from "what is playing" to
  // "which piece and which movement is that".
  const { uris, positionOf, offsetOfItem } = useMemo(() => {
    const flat: string[] = [];
    const where = new Map<string, { item: number; movement: number }>();
    const offsets: number[] = [];
    queue.forEach((item, index) => {
      offsets.push(flat.length);
      item.uris.forEach((uri, movementIndex) => {
        if (!where.has(uri)) {
          where.set(uri, { item: index, movement: movementIndex });
        }
        flat.push(uri);
      });
    });
    return { uris: flat, positionOf: where, offsetOfItem: offsets };
  }, [queue]);

  const send = useCallback((command: PlayerCommand) => {
    frameRef.current?.contentWindow?.postMessage(command, window.location.origin);
  }, []);

  const startAt = useCallback(
    (index: number) => {
      setItemIndex(index);
      setMovement(0);
      send({ kind: "load", uris, offset: offsetOfItem[index] ?? 0 });
    },
    [send, uris, offsetOfItem],
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
      if (message.kind === "hello") {
        // The frame was not listening when the ▶ was pressed; replay.
        if (!readyRef.current) {
          send({ kind: "load", uris, offset: 0 });
        }
        return;
      }
      if (message.kind === "ready") {
        readyRef.current = true;
        return;
      }
      setPaused(message.isPaused);
      const at = positionOf.get(message.uri);
      if (at !== undefined) {
        setItemIndex(at.item);
        setMovement(at.movement);
      }
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, [send, uris, positionOf]);

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
          onClick={() => send({ kind: "previous" })}
          title={cs.player.previous}
        >
          ⏮
        </button>
        <button
          type="button"
          className={styles.control}
          onClick={() => send({ kind: "next" })}
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
