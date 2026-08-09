import { useEffect } from "react";
import styles from "./Toast.module.css";

interface ToastProps {
  message: string | null;
  onDismiss: () => void;
}

export function Toast({ message, onDismiss }: ToastProps) {
  useEffect(() => {
    if (message === null) {
      return;
    }
    const timer = window.setTimeout(onDismiss, 4000);
    return () => window.clearTimeout(timer);
  }, [message, onDismiss]);

  if (message === null) {
    return null;
  }
  return (
    <button type="button" className={styles.toast} onClick={onDismiss} aria-live="polite">
      {message}
    </button>
  );
}
