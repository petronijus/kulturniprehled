import { describe, expect, it } from "vitest";
import type { ProgramMediaLink } from "../api/types";
import type { QueueItem } from "./playQueue";
import { buildQueue, buildSegments, isPlayable, spotifyUriFromUrl } from "./playQueue";

function link(overrides: Partial<ProgramMediaLink> & { key: string }): ProgramMediaLink {
  return {
    author: null,
    work: null,
    spotify_url: null,
    spotify_track_uris: null,
    youtube_url: null,
    match_label: null,
    resolved_at: "2026-08-30T10:00:00Z",
    ...overrides,
  };
}

const MAHLER = "gustav mahler|symfonie c 5";
const JANACEK = "leos janacek|taras bulba";

const LINKS = new Map<string, ProgramMediaLink>([
  [
    MAHLER,
    link({
      key: MAHLER,
      spotify_url: "https://open.spotify.com/album/mahler5?si=abc",
      spotify_track_uris: ["spotify:track:m1", "spotify:track:m2", "spotify:track:m3"],
    }),
  ],
  // Resolved to a record but not to its tracks.
  [JANACEK, link({ key: JANACEK, spotify_url: "https://open.spotify.com/album/taras" })],
]);

const LINES = [
  { author: "Gustav Mahler", work: "Symfonie č. 5" },
  { author: "Leoš Janáček", work: "Taras Bulba" },
  { author: "Neznámý", work: "Nedohledané dílo" },
];

describe("spotifyUriFromUrl", () => {
  it("converts a share link, query string and all", () => {
    expect(spotifyUriFromUrl("https://open.spotify.com/album/xyz?si=1")).toBe("spotify:album:xyz");
    expect(spotifyUriFromUrl("https://open.spotify.com/track/abc")).toBe("spotify:track:abc");
  });

  it("returns null for anything else", () => {
    expect(spotifyUriFromUrl(null)).toBeNull();
    expect(spotifyUriFromUrl("https://youtu.be/x")).toBeNull();
  });
});

describe("buildQueue", () => {
  it("keeps the movements of a work as its own tracks", () => {
    const queue = buildQueue("Česká filharmonie", LINES, LINKS);

    expect(queue).toHaveLength(2);
    expect(queue[0]?.kind).toBe("tracks");
    expect(queue[0]?.uris).toEqual(["spotify:track:m1", "spotify:track:m2", "spotify:track:m3"]);
    expect(queue[0]?.title).toBe("Česká filharmonie");
  });

  it("falls back to the album when only the record was resolved", () => {
    const queue = buildQueue("Česká filharmonie", LINES, LINKS);

    expect(queue[1]?.kind).toBe("album");
    expect(queue[1]?.uris).toEqual(["spotify:album:taras"]);
  });

  it("starts at the clicked piece and plays what follows", () => {
    const queue = buildQueue("Česká filharmonie", LINES, LINKS, 1);

    expect(queue.map((item) => item.work)).toEqual(["Taras Bulba"]);
  });

  it("skips pieces nothing was resolved for", () => {
    const queue = buildQueue("Česká filharmonie", LINES, LINKS, 2);

    expect(queue).toEqual([]);
  });
});

describe("isPlayable", () => {
  it("separates resolved pieces from search-only ones", () => {
    expect(isPlayable({ author: "Gustav Mahler", work: "Symfonie č. 5" }, LINKS)).toBe(true);
    expect(isPlayable({ author: "Neznámý", work: "Nedohledané dílo" }, LINKS)).toBe(false);
  });
});

describe("buildSegments", () => {
  function tracks(key: string, uris: string[]): QueueItem {
    return { key, author: null, work: key, title: "", uris, kind: "tracks", spotifyUrl: null };
  }
  function album(key: string, uri: string): QueueItem {
    return {
      key,
      author: null,
      work: key,
      title: "",
      uris: [uri],
      kind: "album",
      spotifyUrl: null,
    };
  }

  it("runs consecutive track pieces together", () => {
    const { segments, segmentOfItem } = buildSegments([
      tracks("a", ["spotify:track:a1", "spotify:track:a2"]),
      tracks("b", ["spotify:track:b1"]),
    ]);
    expect(segments).toHaveLength(1);
    expect(segments[0]?.uris).toEqual(["spotify:track:a1", "spotify:track:a2", "spotify:track:b1"]);
    expect(segmentOfItem.get(1)).toEqual({ segment: 0, offset: 2 });
  });

  it("gives an album-only piece a segment of its own", () => {
    // Spotify refuses a play request that mixes tracks and an album, and
    // says so only by 400 — the device carries on with the previous music.
    const { segments, segmentOfItem } = buildSegments([
      tracks("a", ["spotify:track:a1"]),
      album("b", "spotify:album:b"),
      tracks("c", ["spotify:track:c1"]),
    ]);
    expect(segments.map((segment) => segment.contextUri)).toEqual([null, "spotify:album:b", null]);
    expect(segments[0]?.uris).toEqual(["spotify:track:a1"]);
    expect(segments[2]?.uris).toEqual(["spotify:track:c1"]);
    expect(segmentOfItem.get(2)).toEqual({ segment: 2, offset: 0 });
  });

  it("never lets a segment exceed Spotify's cap on uris", () => {
    const long = (key: string) =>
      tracks(
        key,
        Array.from({ length: 60 }, (_, index) => `spotify:track:${key}${index}`),
      );
    const { segments, segmentOfItem } = buildSegments([long("a"), long("b")]);
    expect(segments).toHaveLength(2);
    expect(segments.every((segment) => segment.uris.length <= 100)).toBe(true);
    expect(segmentOfItem.get(1)).toEqual({ segment: 1, offset: 0 });
  });

  it("records every occurrence of a recording, not only the first", () => {
    // One record can serve two pieces of a programme; keeping only the first
    // made the panel jump back to it while the second one played.
    const { placeOf } = buildSegments([
      tracks("a", ["spotify:track:shared"]),
      tracks("b", ["spotify:track:shared"]),
    ]);
    expect(placeOf.get("spotify:track:shared")).toEqual([
      { item: 0, movement: 0, segment: 0, offset: 0 },
      { item: 1, movement: 0, segment: 0, offset: 1 },
    ]);
  });
});

describe("a link that is one track, with no movement list", () => {
  const SINGLE = "erik satie|gymnopedie c 1";
  const LINKS_WITH_SINGLE = new Map<string, ProgramMediaLink>([
    [SINGLE, link({ key: SINGLE, spotify_url: "https://open.spotify.com/track/gym1" })],
  ]);

  it("plays as a track, never as a context", () => {
    // `context_uri` takes an album or a playlist; a track uri there is
    // refused, and the refusal never reaches the listener.
    const [item] = buildQueue(
      "Recital",
      [{ author: "Erik Satie", work: "Gymnopédie č. 1" }],
      LINKS_WITH_SINGLE,
    );
    expect(item?.kind).toBe("tracks");
    expect(item?.uris).toEqual(["spotify:track:gym1"]);
    const { segments } = buildSegments(item === undefined ? [] : [item]);
    expect(segments[0]?.contextUri).toBeNull();
    expect(segments[0]?.uris).toEqual(["spotify:track:gym1"]);
  });
});
