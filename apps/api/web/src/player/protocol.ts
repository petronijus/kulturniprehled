/** Messages between the planner and its player frame.
 *
 * The frame exists so the planner itself stays strict: Spotify's Web
 * Playback SDK is third-party code that needs `'unsafe-eval'` and talks to
 * Spotify's own hosts, and it lives in a document that holds no application
 * data and renders nothing but a hidden player.
 *
 * The frame owns the device; the planner owns the running order. Commands
 * carry Spotify track URIs, events carry what is actually playing.
 */

export interface PlayerCommand {
  kind: "load" | "play" | "pause" | "next" | "previous";
  /** For `load`: the whole running order, in playing order. */
  uris?: string[];
  /** For `load`: where in that list to start. */
  offset?: number;
}

export type PlayerEvent =
  /** The frame's script is live and listening — commands sent before this
   * are lost, so the planner waits for it. */
  | { kind: "hello" }
  /** The device exists and playback has been transferred to it. */
  | { kind: "ready" }
  /** No player: no token, no Premium, or the SDK refused to start. */
  | { kind: "failed"; reason: string }
  | { kind: "state"; uri: string; position: number; duration: number; isPaused: boolean };

export function asPlayerEvent(data: unknown): PlayerEvent | null {
  if (typeof data !== "object" || data === null) {
    return null;
  }
  const record = data as Record<string, unknown>;
  const kind = record.kind;
  if (kind === "hello" || kind === "ready") {
    return { kind };
  }
  if (kind === "failed") {
    return { kind, reason: typeof record.reason === "string" ? record.reason : "" };
  }
  if (kind !== "state") {
    return null;
  }
  const { uri, position, duration, isPaused } = record;
  if (
    typeof uri !== "string" ||
    typeof position !== "number" ||
    typeof duration !== "number" ||
    typeof isPaused !== "boolean"
  ) {
    return null;
  }
  return { kind: "state", uri, position, duration, isPaused };
}

export function asPlayerCommand(data: unknown): PlayerCommand | null {
  if (typeof data !== "object" || data === null) {
    return null;
  }
  const record = data as Record<string, unknown>;
  const kind = record.kind;
  if (
    kind !== "load" &&
    kind !== "play" &&
    kind !== "pause" &&
    kind !== "next" &&
    kind !== "previous"
  ) {
    return null;
  }
  if (kind !== "load") {
    return { kind };
  }
  const { uris, offset } = record;
  if (!Array.isArray(uris) || !uris.every((uri): uri is string => typeof uri === "string")) {
    return null;
  }
  return { kind, uris, offset: typeof offset === "number" ? offset : 0 };
}
