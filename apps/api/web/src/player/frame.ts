/** The player frame: a Spotify device of our own, and nothing else.
 *
 * Runs in `/app/player.html`. The embed player this replaced handed
 * playback to Spotify Connect, which routed it to whatever device happened
 * to be "active" — often a stale web-player registration that plays into
 * the void: the progress bar moved and no sound ever came out. A Web
 * Playback SDK device is unambiguous: we create it, we transfer playback to
 * it, and the audio is produced right here.
 *
 * The running order goes to Spotify as a list of track URIs, so movements
 * and pieces follow each other without the planner timing anything.
 */

import type { PlayerCommand, PlayerEvent } from "./protocol";
import { asPlayerCommand } from "./protocol";

const SDK_SRC = "https://sdk.scdn.co/spotify-player.js";
const DEVICE_NAME = "Kulturní Přehled";
const TOKEN_URL = "/v1/season/spotify-token";

interface WebPlaybackTrack {
  uri: string;
  duration_ms: number;
  name: string;
  artists: { name: string }[];
  album: { images: { url: string; height: number | null }[] };
}

interface WebPlaybackState {
  paused: boolean;
  position: number;
  duration: number;
  track_window: { current_track: WebPlaybackTrack | null };
}

interface SpotifyPlayer {
  connect: () => Promise<boolean>;
  addListener: (event: string, callback: (payload: never) => void) => void;
  togglePlay: () => Promise<void>;
  resume: () => Promise<void>;
  pause: () => Promise<void>;
  nextTrack: () => Promise<void>;
  previousTrack: () => Promise<void>;
}

interface SpotifyNamespace {
  Player: new (options: {
    name: string;
    getOAuthToken: (callback: (token: string) => void) => void;
    volume?: number;
  }) => SpotifyPlayer;
}

declare global {
  interface Window {
    onSpotifyWebPlaybackSDKReady?: () => void;
    Spotify?: SpotifyNamespace;
  }
}

function post(event: PlayerEvent): void {
  window.parent.postMessage(event, window.location.origin);
}

let deviceId: string | null = null;
let player: SpotifyPlayer | null = null;
/** Commands that arrived before the device existed. */
let pending: PlayerCommand[] = [];

async function token(): Promise<string> {
  const response = await fetch(TOKEN_URL);
  if (!response.ok) {
    throw new Error(`token ${response.status}`);
  }
  const body = (await response.json()) as { access_token: string };
  return body.access_token;
}

/** Spotify's own queue: hand it the whole running order at once. */
async function playUris(uris: string[], offset: number): Promise<void> {
  if (deviceId === null) {
    return;
  }
  const access = await token();
  await fetch(`https://api.spotify.com/v1/me/player/play?device_id=${deviceId}`, {
    method: "PUT",
    headers: { Authorization: `Bearer ${access}`, "Content-Type": "application/json" },
    body: JSON.stringify({ uris, offset: { position: offset } }),
  });
}

/** Make this device the one that actually sounds. */
async function takeOver(): Promise<void> {
  if (deviceId === null) {
    return;
  }
  const access = await token();
  await fetch("https://api.spotify.com/v1/me/player", {
    method: "PUT",
    headers: { Authorization: `Bearer ${access}`, "Content-Type": "application/json" },
    body: JSON.stringify({ device_ids: [deviceId], play: false }),
  });
}

function apply(command: PlayerCommand): void {
  if (player === null || deviceId === null) {
    pending.push(command);
    return;
  }
  switch (command.kind) {
    case "load":
      void playUris(command.uris ?? [], command.offset ?? 0);
      break;
    case "play":
      void player.resume();
      break;
    case "pause":
      void player.pause();
      break;
    case "next":
      void player.nextTrack();
      break;
    case "previous":
      void player.previousTrack();
      break;
  }
}

window.addEventListener("message", (event: MessageEvent) => {
  if (event.origin !== window.location.origin) {
    return;
  }
  const command = asPlayerCommand(event.data);
  if (command !== null) {
    apply(command);
  }
});

window.onSpotifyWebPlaybackSDKReady = () => {
  const namespace = window.Spotify;
  if (namespace === undefined) {
    post({ kind: "failed", reason: "sdk" });
    return;
  }
  const created = new namespace.Player({
    name: DEVICE_NAME,
    volume: 1,
    getOAuthToken: (callback) => {
      token()
        .then(callback)
        .catch(() => post({ kind: "failed", reason: "token" }));
    },
  });

  created.addListener("ready", (payload: never) => {
    deviceId = (payload as { device_id: string }).device_id;
    player = created;
    void takeOver().then(() => {
      post({ kind: "ready" });
      const queued = pending;
      pending = [];
      for (const command of queued) {
        apply(command);
      }
    });
  });

  created.addListener("player_state_changed", (payload: never) => {
    const state = payload as WebPlaybackState | null;
    if (state === null) {
      return;
    }
    const track = state.track_window.current_track;
    // Smallest image that is still sharp in the panel's 56px slot.
    const cover = [...(track?.album.images ?? [])]
      .sort((a, b) => (a.height ?? 0) - (b.height ?? 0))
      .find((image) => (image.height ?? 0) >= 64);
    post({
      kind: "state",
      uri: track?.uri ?? "",
      position: state.position,
      duration: state.duration,
      isPaused: state.paused,
      trackName: track?.name ?? "",
      artists: (track?.artists ?? []).map((artist) => artist.name).join(", "),
      coverUrl: cover?.url ?? track?.album.images[0]?.url ?? null,
    });
  });

  for (const failure of ["initialization_error", "authentication_error", "account_error"]) {
    created.addListener(failure, (payload: never) => {
      const message = (payload as { message?: string }).message ?? failure;
      post({ kind: "failed", reason: `${failure}: ${message}` });
    });
  }

  void created.connect();
};

// Announce the listener before fetching the SDK: the planner may already be
// holding a running order, and a command sent into a frame that is not
// listening yet is simply lost.
post({ kind: "hello" });

const script = document.createElement("script");
script.src = SDK_SRC;
script.async = true;
script.onerror = () => post({ kind: "failed", reason: "sdk-script" });
document.head.appendChild(script);
