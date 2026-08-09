/** Typed fetch wrapper.
 *
 * The planner is login-less: it is reachable only from the home network
 * (the API blocks /app on the public Cloudflare path), and the backend
 * grants direct header-less requests a season-scoped trusted-LAN
 * principal. A 401 therefore means "not on the home network / trusted-LAN
 * mode disabled", surfaced as `UnauthenticatedError`.
 */

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
    super(401, "not on the trusted home network");
  }
}

async function parseError(response: Response): Promise<ApiError> {
  if (response.status === 401) {
    return new UnauthenticatedError();
  }
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
  const response = await fetch(path, {
    ...init,
    headers: {
      ...init?.headers,
      ...(init?.body !== undefined ? { "Content-Type": "application/json" } : {}),
    },
  });
  if (!response.ok) {
    throw await parseError(response);
  }
  if (response.status === 204) {
    return undefined as T;
  }
  return (await response.json()) as T;
}
