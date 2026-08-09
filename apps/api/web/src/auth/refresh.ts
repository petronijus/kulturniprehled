/** Single-flight refresh.
 *
 * The backend rotates refresh tokens and treats reuse as theft (family
 * revocation, with only a short grace window). Two concurrent 401 handlers
 * both calling /refresh would trip that detection — so every caller awaits
 * one shared in-flight promise. This is correctness, not an optimization.
 */

import type { TokenPair } from "../api/types";
import { clearTokens, getRefreshToken, storeTokens } from "./tokenStore";

let inFlight: Promise<boolean> | null = null;

async function doRefresh(): Promise<boolean> {
  const refreshToken = getRefreshToken();
  if (refreshToken === null) {
    return false;
  }
  const response = await fetch("/v1/auth/refresh", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ refresh_token: refreshToken }),
  });
  if (!response.ok) {
    clearTokens();
    return false;
  }
  const pair = (await response.json()) as TokenPair;
  storeTokens(pair);
  return true;
}

/** Refresh the session; resolves false when the session is gone. */
export function refreshSession(): Promise<boolean> {
  if (inFlight === null) {
    inFlight = doRefresh().finally(() => {
      inFlight = null;
    });
  }
  return inFlight;
}
