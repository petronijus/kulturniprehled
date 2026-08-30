/** The player frame: Spotify's embed API, and nothing else.
 *
 * Runs in `/app/player.html`, whose CSP allows `'unsafe-eval'` (the embed
 * API needs it) and Spotify's script/frame origins. It accepts load/play/
 * pause over postMessage from the planner — same origin only — and reports
 * playback back, which is how the programme hands over between movements.
 */

import type { PlayerCommand, PlayerEvent } from "./protocol";
import { asPlayerCommand } from "./protocol";

const SCRIPT_SRC = "https://open.spotify.com/embed/iframe-api/v1";

interface PlaybackData {
  position: number;
  duration: number;
  isPaused: boolean;
}

interface SpotifyController {
  loadUri: (uri: string) => void;
  play: () => void;
  pause: () => void;
  addListener: (event: string, callback: (payload: { data: PlaybackData }) => void) => void;
}

interface SpotifyIframeApi {
  createController: (
    element: HTMLElement,
    options: { uri: string; width: string | number; height: string | number },
    callback: (controller: SpotifyController) => void,
  ) => void;
}

declare global {
  interface Window {
    onSpotifyIframeApiReady?: (api: SpotifyIframeApi) => void;
  }
}

function post(event: PlayerEvent): void {
  window.parent.postMessage(event, window.location.origin);
}

const host = document.getElementById("embed");
let controller: SpotifyController | null = null;
let api: SpotifyIframeApi | null = null;
/** Commands that arrived before the controller existed. */
let pending: PlayerCommand[] = [];

function createWith(uri: string): void {
  if (api === null || host === null) {
    return;
  }
  api.createController(host, { uri, width: "100%", height: 152 }, (created) => {
    controller = created;
    created.addListener("playback_update", ({ data }) => {
      post({
        kind: "update",
        position: data.position,
        duration: data.duration,
        isPaused: data.isPaused,
      });
    });
    created.addListener("ready", () => created.play());
    created.play();
    post({ kind: "ready" });
  });
}

function apply(command: PlayerCommand): void {
  if (controller === null) {
    // The first load is what the controller gets built with; anything else
    // waits for it.
    if (command.kind === "load" && command.uri !== undefined && api !== null) {
      createWith(command.uri);
      return;
    }
    pending.push(command);
    return;
  }
  if (command.kind === "load" && command.uri !== undefined) {
    controller.loadUri(command.uri);
    controller.play();
  } else if (command.kind === "play") {
    controller.play();
  } else if (command.kind === "pause") {
    controller.pause();
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

window.onSpotifyIframeApiReady = (ready) => {
  api = ready;
  const queued = pending;
  pending = [];
  for (const command of queued) {
    apply(command);
  }
};

// Announce the listener before fetching Spotify's script: the planner may
// already be holding a URI, and a command sent into a frame that is not
// listening yet is simply lost.
post({ kind: "hello" });

const script = document.createElement("script");
script.src = SCRIPT_SRC;
script.async = true;
script.onerror = () => post({ kind: "failed" });
document.head.appendChild(script);
