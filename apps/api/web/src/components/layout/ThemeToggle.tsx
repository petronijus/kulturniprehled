import { useEffect, useState } from "react";
import styles from "./ThemeToggle.module.css";

type Theme = "auto" | "light" | "dark";

const KEY = "kp.theme";
const ORDER: Theme[] = ["auto", "light", "dark"];
const ICON: Record<Theme, string> = { auto: "◐", light: "☀", dark: "☾" };

function applyTheme(theme: Theme): void {
  // With `light-dark()` tokens, forcing a theme is just constraining the
  // root color-scheme; "auto" restores the system preference.
  document.documentElement.style.colorScheme = theme === "auto" ? "light dark" : theme;
}

export function initTheme(): void {
  const stored = localStorage.getItem(KEY);
  if (stored === "light" || stored === "dark") {
    applyTheme(stored);
  }
}

export function ThemeToggle() {
  const [theme, setTheme] = useState<Theme>(() => {
    const stored = localStorage.getItem(KEY);
    return stored === "light" || stored === "dark" ? stored : "auto";
  });

  useEffect(() => {
    applyTheme(theme);
    if (theme === "auto") {
      localStorage.removeItem(KEY);
    } else {
      localStorage.setItem(KEY, theme);
    }
  }, [theme]);

  const cycle = () => {
    const index = ORDER.indexOf(theme);
    const next = ORDER[(index + 1) % ORDER.length] ?? "auto";
    setTheme(next);
  };

  return (
    <button type="button" className={styles.toggle} onClick={cycle} title={`Motiv: ${theme}`}>
      {ICON[theme]}
    </button>
  );
}
