import type { Lane } from "../../api/types";
import { cs } from "../../i18n/cs";
import styles from "./LaneBadge.module.css";

export function LaneBadge({ lane }: { lane: Lane }) {
  return (
    <span
      className={styles.badge}
      style={{ color: `var(--lane-${lane})`, background: `var(--lane-${lane}-bg)` }}
    >
      {cs.lanes[lane]}
    </span>
  );
}
