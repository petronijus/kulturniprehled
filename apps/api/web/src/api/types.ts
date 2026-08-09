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
