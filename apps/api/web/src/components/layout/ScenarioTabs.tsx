import type { Scenario } from "../../api/types";
import { cs } from "../../i18n/cs";
import styles from "./ScenarioTabs.module.css";

interface ScenarioTabsProps {
  scenarios: Scenario[];
  previewScenarioId: string | null;
  onPreview: (scenarioId: string | null) => void;
  onApply: (mode: "replace" | "merge") => void;
  applying: boolean;
}

export function ScenarioTabs({
  scenarios,
  previewScenarioId,
  onPreview,
  onApply,
  applying,
}: ScenarioTabsProps) {
  const preview = scenarios.find((scenario) => scenario.id === previewScenarioId);

  return (
    <div className={styles.wrapper}>
      <div className={styles.tabs} role="tablist">
        <button
          type="button"
          role="tab"
          aria-selected={previewScenarioId === null}
          className={`${styles.tab} ${previewScenarioId === null ? styles.active : ""}`}
          onClick={() => onPreview(null)}
        >
          {cs.myPlan}
        </button>
        {scenarios.map((scenario) => (
          <button
            key={scenario.id}
            type="button"
            role="tab"
            aria-selected={previewScenarioId === scenario.id}
            className={`${styles.tab} ${previewScenarioId === scenario.id ? styles.active : ""}`}
            title={scenario.description_cs ?? undefined}
            onClick={() => onPreview(scenario.id === previewScenarioId ? null : scenario.id)}
          >
            {scenario.name}
          </button>
        ))}
      </div>
      {preview !== undefined && (
        <div className={styles.previewBar}>
          <span className={styles.previewLabel}>
            {cs.scenarioPreview}: <strong>{preview.name}</strong>
            {preview.description_cs !== null && (
              <span className={styles.motto}> — {preview.description_cs}</span>
            )}
          </span>
          <div className={styles.previewActions}>
            <button
              type="button"
              className={styles.applyButton}
              onClick={() => onApply("replace")}
              disabled={applying}
            >
              {cs.applyScenario}
            </button>
            <button
              type="button"
              className={styles.mergeButton}
              onClick={() => onApply("merge")}
              disabled={applying}
            >
              {cs.applyScenarioMerge}
            </button>
            <button type="button" className={styles.exitButton} onClick={() => onPreview(null)}>
              {cs.exitPreview}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
