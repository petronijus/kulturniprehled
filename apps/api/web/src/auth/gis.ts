/** Google Identity Services integration (button flow only — One Tap is
 * unreliable under Safari ITP, and a single-user tool doesn't need it).
 *
 * The client id is baked in at build time via VITE_KP_GOOGLE_CLIENT_ID —
 * the same Web OAuth client the mobile apps use as serverClientId; the SPA
 * origin must be listed in its authorized JavaScript origins.
 */

interface CredentialResponse {
  credential: string;
}

interface GsiButtonConfig {
  theme: "outline" | "filled_black";
  size: "large";
  text: "signin_with";
  width: number;
}

interface GoogleAccountsId {
  initialize(config: { client_id: string; callback: (response: CredentialResponse) => void }): void;
  renderButton(parent: HTMLElement, options: GsiButtonConfig): void;
}

declare global {
  interface Window {
    google?: { accounts: { id: GoogleAccountsId } };
  }
}

const GIS_SRC = "https://accounts.google.com/gsi/client";

let loader: Promise<GoogleAccountsId> | null = null;

function loadGis(): Promise<GoogleAccountsId> {
  if (loader !== null) {
    return loader;
  }
  loader = new Promise<GoogleAccountsId>((resolve, reject) => {
    const existing = window.google?.accounts.id;
    if (existing !== undefined) {
      resolve(existing);
      return;
    }
    const script = document.createElement("script");
    script.src = GIS_SRC;
    script.async = true;
    script.onload = () => {
      const gis = window.google?.accounts.id;
      if (gis === undefined) {
        reject(new Error("GIS loaded but google.accounts.id is missing"));
      } else {
        resolve(gis);
      }
    };
    script.onerror = () => reject(new Error("failed to load Google Identity Services"));
    document.head.appendChild(script);
  });
  return loader;
}

export function googleClientId(): string {
  const clientId = import.meta.env.VITE_KP_GOOGLE_CLIENT_ID;
  if (typeof clientId !== "string" || clientId === "") {
    throw new Error("VITE_KP_GOOGLE_CLIENT_ID is not set");
  }
  return clientId;
}

/** Render the Google sign-in button; resolves each sign-in as an ID token. */
export async function renderSignInButton(
  parent: HTMLElement,
  onIdToken: (idToken: string) => void,
): Promise<void> {
  const gis = await loadGis();
  gis.initialize({
    client_id: googleClientId(),
    callback: (response) => onIdToken(response.credential),
  });
  gis.renderButton(parent, {
    theme: "outline",
    size: "large",
    text: "signin_with",
    width: 280,
  });
}
