/** The programme, playing — in a panel beside the planner.
 *
 * A concert's programme is a running order, so this is a queue, not a link:
 * one movement follows the next, one work follows the previous, and the
 * panel stays put while Petr keeps planning. Advancing is driven by
 * Spotify's `playback_update` (the embed has no "ended" event): a track
 * that has reached its duration hands over to the next URI.
 */

import { useCallback, useEffect, useRef, useState } from "react";
import type { QueueItem } from "../../domain/playQueue";
import { cs } from "../../i18n/cs";
import styles from "./ProgramPlayer.module.css";
import type { SpotifyController } from "./spotifyIframeApi";
import { loadSpotifyIframeApi } from "./spotifyIframeApi";

interface ProgramPlayerProps {
  queue: QueueItem[];
  onClose: () => void;
}

/** How close to the end counts as finished — the embed's last update never
 * lands exactly on the duration. */
const END_SLACK_MS = 900;

interface Position {
  item: number;
  movement: number;
}

export function ProgramPlayer({ queue, onClose }: ProgramPlayerProps) {
  const [position, setPosition] = useState<Position>({ item: 0, movement: 0 });
  const [paused, setPaused] = useState(true);
  const [failed, setFailed] = useState(false);
  const hostRef = useRef<HTMLDivElement>(null);
  const controllerRef = useRef<SpotifyController | null>(null);
  // The URI the controller is currently on, so one `playback_update` per
  // track can trigger exactly one hand-over.
  const playingRef = useRef<string | null>(null);
  // The embed loads paused, and `play()` right after `loadUri()` can land
  // before the iframe is ready — so "start this one" is a standing wish,
  // retried on `ready` and on the first paused-at-zero update, and dropped
  // the moment playback actually starts (never fighting a manual pause).
  const wantPlayRef = useRef(true);
  const advanceRef = useRef<() => void>(() => {});

  const current = queue[position.item];
  const uri = current?.uris[position.movement] ?? null;
  // The URI the controller is created with. A ref, because the controller is
  // built once and every later URI arrives through loadUri.
  const seedUriRef = useRef(uri);

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

  // One controller for the panel's lifetime; the queue is driven by
  // loadUri, never by re-creating the iframe.
  useEffect(() => {
    const host = hostRef.current;
    const seed = seedUriRef.current;
    if (host === null || seed === null) {
      return;
    }
    let disposed = false;
    loadSpotifyIframeApi()
      .then((api) => {
        if (disposed) {
          return;
        }
        api.createController(host, { uri: seed, width: "100%", height: 152 }, (controller) => {
          if (disposed) {
            controller.destroy();
            return;
          }
          controllerRef.current = controller;
          playingRef.current = seed;
          controller.addListener("ready", () => {
            if (wantPlayRef.current) {
              controller.play();
            }
          });
          controller.addListener("playback_update", ({ data }) => {
            setPaused(data.isPaused);
            if (!data.isPaused) {
              wantPlayRef.current = false;
            } else if (wantPlayRef.current && data.position === 0) {
              controller.play();
            }
            if (data.duration > 0 && data.position >= data.duration - END_SLACK_MS) {
              advanceRef.current();
            }
          });
          controller.play();
        });
      })
      .catch(() => setFailed(true));
    return () => {
      disposed = true;
      controllerRef.current?.destroy();
      controllerRef.current = null;
      playingRef.current = null;
    };
  }, []);

  // Push the current URI into the existing controller and start it.
  useEffect(() => {
    const controller = controllerRef.current;
    if (controller === null || uri === null || playingRef.current === uri) {
      return;
    }
    playingRef.current = uri;
    wantPlayRef.current = true;
    controller.loadUri(uri);
    controller.play();
  }, [uri]);

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

      <div ref={hostRef} className={styles.embed} />
      {failed && <p className={styles.failed}>{cs.player.failed}</p>}

      <div className={styles.controls}>
        <button
          type="button"
          className={styles.control}
          onClick={() => {
            const controller = controllerRef.current;
            if (controller === null) {
              return;
            }
            wantPlayRef.current = false;
            if (paused) {
              controller.play();
            } else {
              controller.pause();
            }
          }}
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
