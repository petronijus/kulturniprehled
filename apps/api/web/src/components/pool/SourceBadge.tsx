import styles from "./SourceBadge.module.css";

/** Ensemble / festival provenance badge — same color scheme as the
 * weekly digest e-mails (festival = orange, sezónní těleso = grey,
 * objev = green). */
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
  return (
    <span
      className={styles.badge}
      style={{
        color: `var(--source-${kind})`,
        background: `var(--source-${kind}-bg)`,
      }}
    >
      {sourceName}
    </span>
  );
}
