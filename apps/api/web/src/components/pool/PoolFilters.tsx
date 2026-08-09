import type { Lane } from "../../api/types";
import type { IsoMonth } from "../../domain/season";
import { cs } from "../../i18n/cs";
import styles from "./PoolFilters.module.css";

export interface PoolFilterState {
  lane: Lane | null;
  month: IsoMonth | null;
  undecidedOnly: boolean;
  newOnly: boolean;
  query: string;
}

export const defaultFilters: PoolFilterState = {
  lane: null,
  month: null,
  undecidedOnly: false,
  newOnly: false,
  query: "",
};

const LANES: Lane[] = ["klasika", "elektronika", "divadlo", "film"];

interface PoolFiltersProps {
  filters: PoolFilterState;
  months: IsoMonth[];
  onChange: (filters: PoolFilterState) => void;
}

export function PoolFilters({ filters, months, onChange }: PoolFiltersProps) {
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
        <select
          className={styles.select}
          value={filters.month ?? ""}
          onChange={(event) =>
            onChange({ ...filters, month: event.target.value === "" ? null : event.target.value })
          }
        >
          <option value="">{cs.filters.month}</option>
          {months.map((month) => {
            const index = Number(month.slice(5)) - 1;
            return (
              <option key={month} value={month}>
                {cs.months[index]} {month.slice(0, 4)}
              </option>
            );
          })}
        </select>
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
