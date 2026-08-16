/** API contract types — mirrors apps/api `domain/schemas.py`. */

export type Lane = "klasika" | "elektronika" | "divadlo" | "film";
export type PlanStatus = "undecided" | "selected" | "rejected";

export interface Season {
  id: string;
  workspace_id: string;
  label: string;
  starts_on: string;
  ends_on: string;
  status: "active" | "archived";
  novelty_ack_at: string | null;
  version: number;
  created_at: string;
  updated_at: string;
}

export interface ProgramEntry {
  composer?: string;
  work?: string;
  author?: string;
  play?: string;
  director?: string;
  film?: string;
  [key: string]: unknown;
}

export interface Candidate {
  id: string;
  season_id: string;
  workspace_id: string;
  dedup_key: string;
  lane: Lane;
  title: string;
  starts_at: string;
  ends_at: string | null;
  venue: string | null;
  url: string | null;
  price_czk: string | null;
  program: ProgramEntry[] | null;
  detail: Record<string, unknown> | null;
  enriched_at: string | null;
  score: number | null;
  why_cs: string | null;
  source_type: string | null;
  source_name: string | null;
  season_event: boolean;
  tickets_available: boolean | null;
  plan_status: PlanStatus;
  plan_status_at: string | null;
  note: string | null;
  first_seen_at: string;
  last_seen_at: string;
  version: number;
  created_at: string;
  updated_at: string;
}

export interface ReservedSlot {
  lane: Lane;
  month: string;
  note_cs: string | null;
}

export interface Scenario {
  id: string;
  season_id: string;
  name: string;
  description_cs: string | null;
  rank: number;
  candidate_ids: string[];
  reserved_slots: ReservedSlot[] | null;
  generated_at: string;
  applied_at: string | null;
  version: number;
  created_at: string;
  updated_at: string;
}

export interface PoolListResponse {
  items: Candidate[];
  total: number;
}

export interface ScenarioListResponse {
  items: Scenario[];
}

export interface PlanCounts {
  selected: number;
  rejected: number;
  undecided: number;
}

export interface PlanWeek {
  iso_week: string;
  count: number;
}

export interface PlanSummary {
  selected: Candidate[];
  counts: PlanCounts;
  weeks: PlanWeek[];
  applied_scenario_id: string | null;
}

/** Booked KP event (from GET /v1/season/plans/{id}/booked). */
export interface BookedEvent {
  id: string;
  title: string;
  category: string;
  starts_at: string;
}

export interface SeasonBookedResponse {
  items: BookedEvent[];
}

/** One local day occupied by one event of the shared household calendar
 * (Kocourek&Prdelčička). A multi-day event yields one entry per day it
 * covers — `span_index` / `span_days` say which. */
export interface CalendarEntry {
  uid: string;
  title: string;
  day: string;
  all_day: boolean;
  starts_at: string | null;
  ends_at: string | null;
  /** Counts into `blocked_days` — the planner must not book this day. */
  blocking: boolean;
  span_days: number;
  span_index: number;
}

export interface CalendarConflict {
  start_iso: string;
  end_iso: string;
  title: string;
}

/** A public holiday — a mark in the grid, never a planning rule. */
export interface Holiday {
  day: string;
  title: string;
}

/** GET /v1/season/holidays. Separate from the household calendar so one feed
 * being down cannot blank the other. */
export interface HolidayView {
  available: boolean;
  unavailable_reason: string | null;
  range_start: string;
  range_end: string;
  days: Holiday[];
}

/** GET /v1/season/calendar. `available: false` (no feed configured, or the
 * feed is unreachable and nothing was cached) is a normal answer — the
 * planner renders without the calendar layer. */
export interface CalendarView {
  available: boolean;
  unavailable_reason: string | null;
  calendar_name: string | null;
  fetched_at: string | null;
  range_start: string;
  range_end: string;
  blocked_days: string[];
  conflicts: CalendarConflict[];
  entries: CalendarEntry[];
}
