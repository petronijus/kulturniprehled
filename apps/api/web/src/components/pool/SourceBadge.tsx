import { logoFor } from "../../domain/sources";
import styles from "./SourceBadge.module.css";

/** Ensemble / festival provenance badge — same color scheme as the
 * weekly digest e-mails (festival = orange, sezónní těleso = grey,
 * objev = green), with the organisation's logo when we have one. */
export function SourceBadge({
  sourceType,
  sourceName,
}: {
  sourceType: string | null;
  sourceName: string | null;
}) {
  if (sourceName === null) {
    return null;
  }
  const kind = sourceType === "festival" || sourceType === "objev" ? sourceType : "sezona";
  const logo = logoFor(sourceName);
  return (
    <span
      className={styles.badge}
      style={{
        color: `var(--source-${kind})`,
        background: `var(--source-${kind}-bg)`,
      }}
    >
      {logo !== null && <img className={styles.logo} src={logo} alt="" aria-hidden="true" />}
      {sourceName}
    </span>
  );
}
