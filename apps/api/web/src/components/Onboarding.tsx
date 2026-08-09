import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "../api/client";
import { queryKeys } from "../api/queries";
import type { Season } from "../api/types";
import { isoToLocalDate, seasonWindowFor } from "../domain/season";
import { cs } from "../i18n/cs";
import styles from "./Onboarding.module.css";

/** First-run screen: no season exists yet. One click creates it — the
 * calendar appears immediately; candidates arrive later via the
 * /kulturni-sezona scrape (explained by the empty-pool state). */
export function Onboarding() {
  const queryClient = useQueryClient();
  const window = seasonWindowFor(isoToLocalDate(new Date().toISOString()));

  const create = useMutation({
    mutationFn: () =>
      api<Season>("/v1/season/plans", {
        method: "POST",
        body: JSON.stringify({
          label: window.label,
          starts_on: window.startsOn,
          ends_on: window.endsOn,
        }),
      }),
    onSuccess: (season) => {
      queryClient.setQueryData(queryKeys.season, season);
      void queryClient.invalidateQueries({ queryKey: queryKeys.season });
    },
  });

  return (
    <div className={styles.screen}>
      <div className={styles.card}>
        <p className={styles.brand}>
          {cs.appTitle} · {cs.appSubtitle}
        </p>
        <h1 className={styles.title}>{cs.onboarding.title}</h1>
        <p className={styles.lead}>{cs.onboarding.lead}</p>
        <button
          type="button"
          className={styles.create}
          onClick={() => create.mutate()}
          disabled={create.isPending}
        >
          {create.isPending ? cs.onboarding.creating : cs.onboarding.create(window.label)}
        </button>
        <p className={styles.window}>{cs.onboarding.window(window.label)}</p>
        {create.isError && <p className={styles.error}>{cs.onboarding.createFailed}</p>}
      </div>
    </div>
  );
}
