/** Loader for Spotify's embed iframe API.
 *
 * The script is the planner's only third-party code (CSP allows exactly
 * `open.spotify.com`, see `kp_api/observability.py`). It is fetched once per
 * page and the promise is cached, so several mounts — StrictMode's double
 * mount included — share one load.
 *
 * The player it hands back is the embed player: full tracks for a viewer
 * logged into Spotify in this browser, 30-second previews otherwise. That
 * is the price of not asking the planner for a Spotify login.
 */

const SCRIPT_SRC = "https://open.spotify.com/embed/iframe-api/v1";

export interface PlaybackData {
  /** Milliseconds. */
  position: number;
  /** Milliseconds; 0 until the track is loaded. */
  duration: number;
  isPaused: boolean;
  isBuffering: boolean;
}

export interface SpotifyController {
  loadUri: (uri: string) => void;
  play: () => void;
  pause: () => void;
  destroy: () => void;
  addListener: (event: string, callback: (payload: { data: PlaybackData }) => void) => void;
}

export interface SpotifyIframeApi {
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

let pending: Promise<SpotifyIframeApi> | null = null;

export function loadSpotifyIframeApi(): Promise<SpotifyIframeApi> {
  if (pending !== null) {
    return pending;
  }
  pending = new Promise<SpotifyIframeApi>((resolve, reject) => {
    window.onSpotifyIframeApiReady = resolve;
    const script = document.createElement("script");
    script.src = SCRIPT_SRC;
    script.async = true;
    script.onerror = () => {
      pending = null;
      reject(new Error("Spotify iframe API failed to load"));
    };
    document.head.appendChild(script);
  });
  return pending;
}
