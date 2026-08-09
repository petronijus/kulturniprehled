import { useEffect, useRef, useState } from "react";
import { cs } from "../i18n/cs";
import { useAuth } from "./AuthProvider";
import { renderSignInButton } from "./gis";
import styles from "./LoginScreen.module.css";

export function LoginScreen() {
  const { signIn } = useAuth();
  const buttonHost = useRef<HTMLDivElement>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const host = buttonHost.current;
    if (host === null) {
      return;
    }
    renderSignInButton(host, (idToken) => {
      void signIn(idToken).catch(() => setError(cs.loadFailed));
    }).catch(() => setError(cs.loadFailed));
  }, [signIn]);

  return (
    <div className={styles.screen}>
      <div className={styles.card}>
        <h1 className={styles.title}>{cs.appTitle}</h1>
        <p className={styles.subtitle}>{cs.appSubtitle}</p>
        <div ref={buttonHost} className={styles.button} />
        {error !== null && <p className={styles.error}>{error}</p>}
      </div>
    </div>
  );
}
