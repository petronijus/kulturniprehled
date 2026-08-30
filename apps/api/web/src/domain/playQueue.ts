/** Turning a printed programme into something that plays.
 *
 * Two things make this less obvious than "open the link": a classical work
 * is several tracks (movements), and a programme is several works. Clicking
 * ▶ on the third piece means "play this piece and everything after it", so
 * the queue is flat — every movement of every remaining piece, in order.
 */

import type { ProgramMediaLink } from "../api/types";
import type { ProgramLine } from "./program";
import { programKey } from "./programKey";

export interface QueueItem {
  /** Folded piece identity — also the React key. */
  key: string;
  author: string | null;
  work: string | null;
  /** The concert this piece was queued from, for the panel header. */
  title: string;
  /** Spotify URIs to play in order: the movements, or one album. */
  uris: string[];
  /** `album` means the resolver only found the record, not the tracks —
   * playing it may run past the end of the work. */
  kind: "tracks" | "album";
  /** Human link, for "open in Spotify". */
  spotifyUrl: string | null;
}

const SPOTIFY_URL = /open\.spotify\.com\/(album|track|playlist)\/([A-Za-z0-9]+)/;

/** `https://open.spotify.com/album/xyz?si=…` → `spotify:album:xyz`. */
export function spotifyUriFromUrl(url: string | null): string | null {
  if (url === null) {
    return null;
  }
  const match = SPOTIFY_URL.exec(url);
  return match === null ? null : `spotify:${match[1]}:${match[2]}`;
}

function itemFor(line: ProgramLine, title: string, link: ProgramMediaLink): QueueItem | null {
  const key = programKey(line.author, line.work);
  if (key === null) {
    return null;
  }
  const tracks = link.spotify_track_uris ?? [];
  if (tracks.length > 0) {
    return {
      key,
      author: line.author,
      work: line.work,
      title,
      uris: tracks,
      kind: "tracks",
      spotifyUrl: link.spotify_url,
    };
  }
  const albumUri = spotifyUriFromUrl(link.spotify_url);
  if (albumUri === null) {
    return null;
  }
  return {
    key,
    author: line.author,
    work: line.work,
    title,
    uris: [albumUri],
    kind: "album",
    spotifyUrl: link.spotify_url,
  };
}

/** Look a piece up in the resolved-link map. */
export function linkFor(
  line: ProgramLine,
  links: ReadonlyMap<string, ProgramMediaLink>,
): ProgramMediaLink | undefined {
  const key = programKey(line.author, line.work);
  return key === null ? undefined : links.get(key);
}

/** True when ▶ can play the piece in place rather than open a search. */
export function isPlayable(
  line: ProgramLine,
  links: ReadonlyMap<string, ProgramMediaLink>,
): boolean {
  const link = linkFor(line, links);
  return link !== undefined && itemFor(line, "", link) !== null;
}

/** The playable pieces from `startIndex` on — unresolved ones are skipped. */
export function buildQueue(
  title: string,
  lines: readonly ProgramLine[],
  links: ReadonlyMap<string, ProgramMediaLink>,
  startIndex = 0,
): QueueItem[] {
  const queue: QueueItem[] = [];
  for (const line of lines.slice(startIndex)) {
    const link = linkFor(line, links);
    if (link === undefined) {
      continue;
    }
    const item = itemFor(line, title, link);
    if (item !== null) {
      queue.push(item);
    }
  }
  return queue;
}
