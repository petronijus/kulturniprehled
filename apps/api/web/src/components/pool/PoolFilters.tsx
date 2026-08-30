import { useMemo } from "react";
import type { Lane } from "../../api/types";
import type { PoolFacets } from "../../domain/facets";
import type { IsoMonth } from "../../domain/season";
import { cs } from "../../i18n/cs";
import type { SelectOption } from "../ui/Select";
import { Select } from "../ui/Select";
import styles from "./PoolFilters.module.css";

export interface PoolFilterState {
  lane: Lane | null;
  month: IsoMonth | null;
  /** Encoded `source:…` / `venue:…`, or null for every ensemble and venue. */
  facet: string | null;
  undecidedOnly: boolean;
  newOnly: boolean;
  /** Fully rejected productions are hidden unless this is on. */
  showRejected: boolean;
  query: string;
}

export const defaultFilters: PoolFilterState = {
  lane: null,
  month: null,
  facet: null,
  undecidedOnly: false,
  newOnly: false,
  showRejected: false,
  query: "",
};

const LANES: Lane[] = ["klasika", "elektronika", "divadlo", "film"];

interface PoolFiltersProps {
  filters: PoolFilterState;
  months: IsoMonth[];
  facets: PoolFacets;
  onChange: (filters: PoolFilterState) => void;
}

export function PoolFilters({ filters, months, facets, onChange }: PoolFiltersProps) {
  const monthOptions = useMemo<SelectOption[]>(
    () =>
      months.map((month) => ({
        value: month,
        label: `${cs.months[Number(month.slice(5)) - 1] ?? month} ${month.slice(0, 4)}`,
      })),
    [months],
  );
  // Ensembles and venues share one control, each half under its own heading.
  const facetOptions = useMemo<SelectOption[]>(
    () => [
      ...facets.sources.map((name) => ({
        value: `source:${name}`,
        label: name,
        group: cs.filters.facetSources,
      })),
      ...facets.venues.map((name) => ({
        value: `venue:${name}`,
        label: name,
        group: cs.filters.facetVenues,
      })),
    ],
    [facets],
  );

  return (
    <div className={styles.bar}>
      <div className={styles.laneChips}>
        <button
          type="button"
          className={`${styles.chip} ${filters.lane === null ? styles.chipActive : ""}`}
          onClick={() => onChange({ ...filters, lane: null })}
        >
          {cs.filters.all}
        </button>
        {LANES.map((lane) => (
          <button
            key={lane}
            type="button"
            className={`${styles.chip} ${filters.lane === lane ? styles.chipActive : ""}`}
            style={filters.lane === lane ? { color: `var(--lane-${lane})` } : undefined}
            onClick={() => onChange({ ...filters, lane: filters.lane === lane ? null : lane })}
          >
            {cs.lanes[lane]}
          </button>
        ))}
      </div>
      <div className={styles.row}>
        <Select
          value={filters.month ?? ""}
          options={monthOptions}
          placeholder={cs.filters.month}
          onChange={(value) => onChange({ ...filters, month: value === "" ? null : value })}
        />
        <Select
          value={filters.facet ?? ""}
          options={facetOptions}
          placeholder={cs.filters.facet}
          onChange={(value) => onChange({ ...filters, facet: value === "" ? null : value })}
        />
        <label className={styles.toggle}>
          <input
            type="checkbox"
            checked={filters.undecidedOnly}
            onChange={(event) => onChange({ ...filters, undecidedOnly: event.target.checked })}
          />
          {cs.filters.undecidedOnly}
        </label>
        <label className={styles.toggle}>
          <input
            type="checkbox"
            checked={filters.newOnly}
            onChange={(event) => onChange({ ...filters, newOnly: event.target.checked })}
          />
          {cs.filters.newOnly}
        </label>
        <label className={styles.toggle}>
          <input
            type="checkbox"
            checked={filters.showRejected}
            onChange={(event) => onChange({ ...filters, showRejected: event.target.checked })}
          />
          {cs.filters.showRejected}
        </label>
      </div>
      <input
        type="search"
        className={styles.search}
        placeholder={cs.filters.search}
        value={filters.query}
        onChange={(event) => onChange({ ...filters, query: event.target.value })}
      />
    </div>
  );
}
