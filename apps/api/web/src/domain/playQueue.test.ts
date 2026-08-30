import { describe, expect, it } from "vitest";
import type { ProgramMediaLink } from "../api/types";
import { buildQueue, isPlayable, spotifyUriFromUrl } from "./playQueue";

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
