/** Token lifecycle: access token in memory, refresh token in localStorage.
 *
 * Storing the refresh token in localStorage is a documented tradeoff for a
 * single-user self-hosted app behind a strict CSP (the only third-party
 * script is Google Identity Services): the backend's rotation + family
 * reuse detection limits the blast radius of a leak.
 */

import type { TokenPair } from "../api/types";

const REFRESH_KEY = "kp.refreshToken";

let accessToken: string | null = null;
let accessExpiresAt = 0;

export function storeTokens(pair: TokenPair): void {
  accessToken = pair.access_token;
  accessExpiresAt = Date.parse(pair.access_expires_at);
  localStorage.setItem(REFRESH_KEY, pair.refresh_token);
}

export function clearTokens(): void {
  accessToken = null;
  accessExpiresAt = 0;
  localStorage.removeItem(REFRESH_KEY);
}

export function getAccessToken(): string | null {
  return accessToken;
}

/** True when the access token is missing or within 60 s of expiry. */
export function accessTokenStale(): boolean {
  return accessToken === null || Date.now() > accessExpiresAt - 60_000;
}

export function getRefreshToken(): string | null {
  return localStorage.getItem(REFRESH_KEY);
}

export function hasSession(): boolean {
  return getRefreshToken() !== null;
}
