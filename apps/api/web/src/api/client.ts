/** Typed fetch wrapper: bearer auth, proactive + reactive refresh, and
 * typed 409 version-conflict errors. */

import { refreshSession } from "../auth/refresh";
import {
  accessTokenStale,
  clearTokens,
  getAccessToken,
  getRefreshToken,
  storeTokens,
} from "../auth/tokenStore";
import type { TokenPair } from "./types";

export class ApiError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export class VersionMismatchError extends ApiError {
  readonly currentVersion: number;

  constructor(currentVersion: number) {
    super(409, "version mismatch");
    this.currentVersion = currentVersion;
  }
}

export class UnauthenticatedError extends ApiError {
  constructor() {
    super(401, "not authenticated");
  }
}

/** Notifies the auth provider that the session died mid-flight. */
let onSessionLost: (() => void) | null = null;

export function setSessionLostHandler(handler: () => void): void {
  onSessionLost = handler;
}

async function ensureFreshToken(): Promise<string> {
  if (accessTokenStale()) {
    const ok = await refreshSession();
    if (!ok) {
      onSessionLost?.();
      throw new UnauthenticatedError();
    }
  }
  const token = getAccessToken();
  if (token === null) {
    onSessionLost?.();
    throw new UnauthenticatedError();
  }
  return token;
}

async function parseError(response: Response): Promise<ApiError> {
  if (response.status === 409) {
    try {
      const body = (await response.json()) as {
        detail?: { code?: string; current_version?: number };
      };
      if (body.detail?.code === "version_mismatch" && body.detail.current_version !== undefined) {
        return new VersionMismatchError(body.detail.current_version);
      }
    } catch {
      // fall through to the generic error
    }
  }
  return new ApiError(response.status, `${response.status} ${response.statusText}`);
}

export async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const token = await ensureFreshToken();
  const request = (bearer: string) =>
    fetch(path, {
      ...init,
      headers: {
        ...init?.headers,
        Authorization: `Bearer ${bearer}`,
        ...(init?.body !== undefined ? { "Content-Type": "application/json" } : {}),
      },
    });

  let response = await request(token);
  if (response.status === 401) {
    // The token may have been revoked server-side; retry once after a
    // forced refresh, then give up.
    const ok = await refreshSession();
    const retryToken = getAccessToken();
    if (!ok || retryToken === null) {
      onSessionLost?.();
      throw new UnauthenticatedError();
    }
    response = await request(retryToken);
  }
  if (!response.ok) {
    throw await parseError(response);
  }
  if (response.status === 204) {
    return undefined as T;
  }
  return (await response.json()) as T;
}

/** Exchange a Google ID token for the app's token pair. */
export async function loginWithGoogle(idToken: string): Promise<void> {
  const response = await fetch("/v1/auth/google", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ id_token: idToken }),
  });
  if (!response.ok) {
    throw new ApiError(response.status, "Google sign-in was rejected");
  }
  storeTokens((await response.json()) as TokenPair);
}

export async function logout(): Promise<void> {
  try {
    const refreshToken = getRefreshToken();
    if (refreshToken !== null) {
      await fetch("/v1/auth/logout", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ refresh_token: refreshToken }),
      });
    }
  } finally {
    clearTokens();
  }
}
