/** Messages between the planner and its player frame.
 *
 * The frame exists for one reason: Spotify's embed API evaluates code at
 * runtime, so its document needs `'unsafe-eval'`. Keeping it in a separate
 * same-origin page confines that relaxation to a document that holds no app
 * data and renders nothing but the embed — the planner itself keeps the
 * strict policy.
 */

export interface PlayerCommand {
  kind: "load" | "play" | "pause";
  /** Spotify URI, for `load`. */
  uri?: string;
}

export type PlayerEvent =
  /** The frame's script is live and listening — commands sent before this
   * are lost, so the planner waits for it before loading anything. */
  | { kind: "hello" }
  | { kind: "ready" }
  | { kind: "failed" }
  | { kind: "update"; position: number; duration: number; isPaused: boolean };

/** Guards a `message` payload without trusting its shape. */
export function asPlayerEvent(data: unknown): PlayerEvent | null {
  if (typeof data !== "object" || data === null) {
    return null;
  }
  const kind = (data as { kind?: unknown }).kind;
  if (kind === "hello" || kind === "ready" || kind === "failed") {
    return { kind };
  }
  if (kind !== "update") {
    return null;
  }
  const { position, duration, isPaused } = data as Record<string, unknown>;
  if (
    typeof position !== "number" ||
    typeof duration !== "number" ||
    typeof isPaused !== "boolean"
  ) {
    return null;
  }
  return { kind: "update", position, duration, isPaused };
}

export function asPlayerCommand(data: unknown): PlayerCommand | null {
  if (typeof data !== "object" || data === null) {
    return null;
  }
  const { kind, uri } = data as Record<string, unknown>;
  if (kind !== "load" && kind !== "play" && kind !== "pause") {
    return null;
  }
  if (kind === "load" && typeof uri !== "string") {
    return null;
  }
  return kind === "load" ? { kind, uri: uri as string } : { kind };
}
