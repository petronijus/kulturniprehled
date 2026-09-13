/** Turning a printed programme into something that plays.
 *
 * Two things make this less obvious than "open the link": a classical work
 * is several tracks (movements), and a programme is several works. Clicking
 * ▶ on the third piece means "play this piece and everything after it", so
 * the queue is flat — every movement of every remaining piece, in order.
 */

import type { ProgramMediaLink } from "../api/types";
import { MAX_URIS } from "../player/protocol";
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
  const uri = spotifyUriFromUrl(link.spotify_url);
  if (uri === null) {
    return null;
  }
  // What the link points at decides how it plays, not whether movements were
  // found. 19 pieces in the 2026/27 pool resolved to a single track with no
  // movement list; calling those "album" sent a track uri as a play context,
  // which Spotify rejects — silently, so the panel showed the piece and the
  // device kept playing whatever came before.
  const single = uri.startsWith("spotify:track:");
  return {
    key,
    author: line.author,
    work: line.work,
    title,
    uris: [uri],
    kind: single ? "tracks" : "album",
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

/** One `load` the player frame can accept.
 *
 * Spotify's play endpoint takes EITHER a list of track uris OR one context
 * (an album), never both, and at most `MAX_URIS` of the former. A request
 * that breaks either rule is rejected — and a rejected request is silent:
 * the device keeps playing whatever it held, so the panel shows the piece
 * that was picked while something entirely else comes out of the speakers.
 * That is what this split exists to prevent.
 */
export interface Segment {
  /** An album to play whole; `null` when this segment is a track run. */
  contextUri: string | null;
  /** Indices into the queue this segment covers, in playing order. */
  items: number[];
  uris: string[];
}

/** Where one track uri sits: which piece, which movement, which segment. */
export interface Place {
  item: number;
  movement: number;
  segment: number;
  offset: number;
}

/** Cut the running order into loads, and index every track occurrence.
 *
 * Consecutive track-resolved pieces share a segment so their movements run
 * on without the panel timing anything; an album-only piece is a segment of
 * its own. Every occurrence of a uri is recorded, not just the first — one
 * recording can serve two pieces of a programme, and keeping only the first
 * made the panel jump back to it mid-playback.
 */
export function buildSegments(queue: readonly QueueItem[]): {
  segments: Segment[];
  placeOf: Map<string, Place[]>;
  segmentOfItem: Map<number, { segment: number; offset: number }>;
} {
  const segments: Segment[] = [];
  const placeOf = new Map<string, Place[]>();
  const segmentOfItem = new Map<number, { segment: number; offset: number }>();
  let run: Segment | null = null;

  queue.forEach((item, index) => {
    if (item.kind === "album") {
      segments.push({ contextUri: item.uris[0] ?? null, items: [index], uris: [] });
      segmentOfItem.set(index, { segment: segments.length - 1, offset: 0 });
      run = null;
      return;
    }
    if (run === null || run.uris.length + item.uris.length > MAX_URIS) {
      run = { contextUri: null, items: [], uris: [] };
      segments.push(run);
    }
    const segment = run;
    const segmentIndex = segments.length - 1;
    segmentOfItem.set(index, { segment: segmentIndex, offset: segment.uris.length });
    segment.items.push(index);
    item.uris.forEach((uri, movement) => {
      const places = placeOf.get(uri) ?? [];
      places.push({ item: index, movement, segment: segmentIndex, offset: segment.uris.length });
      placeOf.set(uri, places);
      segment.uris.push(uri);
    });
  });
  return { segments, placeOf, segmentOfItem };
}
