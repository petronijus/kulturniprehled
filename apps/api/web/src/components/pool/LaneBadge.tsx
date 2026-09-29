import type { Lane } from "../../api/types";
import { en } from "../../i18n/en";
import styles from "./LaneBadge.module.css";

export function LaneBadge({ lane }: { lane: Lane }) {
  return (
    <span
      className={styles.badge}
      style={{ color: `var(--lane-${lane})`, background: `var(--lane-${lane}-bg)` }}
    >
      {en.lanes[lane]}
    </span>
  );
}
