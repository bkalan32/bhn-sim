// The shapes the API returns (services/mission-control/app.py and the bot's records it proxies).

export type Part<T> = { ok: true; ms: number; data: T } | { ok: false; error: string };

export type Health = Partial<Record<"activation" | "egift" | "settlement" | "platform", number>>;

export type FiringAlert = {
  alertname: string;
  service: string | null;
  severity: string;
  startsAt: string;
  summary: string | null;
};

export type IncidentSummary = {
  id: string;
  status: "open" | "resolved";
  service: string | null;
  severity: string;
  alerts: string[];
  opened_at_iso: string;
  resolved_at_iso: string | null;
  duration_min: number | null;
  closed_by_human?: { by: string; reason: string; at_iso: string } | null;
};

export type Approval = {
  token: string;
  action: string;
  params: Record<string, unknown>;
  reason: string | null;
  tier: number;
  entrance: string;
  operator: string;
  incident?: string | null;
  created_at_iso: string;
  expires_at_iso: string;
  source: "mission-control" | "remediator";
};

export type Overview = {
  generated_at: string;
  ms: number;
  health: Part<Health>;
  sparklines: Part<Record<string, number[]>>;
  alerts: Part<FiringAlert[]>;
  incidents: Part<IncidentSummary[]>;
  approvals: Part<Approval[]>;
  deploys_today: Part<{ time_ms: number; text: string; tags: string[] }[]>;
  settlement_age_s: Part<number | null>;
  traffic: Part<{ rps: Record<string, number>; multiplier: Record<string, number> }>;
  needs_human?: Part<NeedsHuman>;
};

export type AuditRow = {
  id: number;
  ts: number;
  ts_iso: string;
  operator: string;
  action: string;
  params: Record<string, unknown>;
  tier: number;
  approval_token: string | null;
  entrance: string;
  result: string;
  detail: string | null;
};

export type Action = {
  id: string;
  tier: 1 | 2;
  title: string;
  params: string[];
  blast_radius: string;
  rationale: string;
  services?: string[];
  scenarios?: string[];
  knobs?: Record<string, Record<string, { type: string; range: unknown; baseline: string }>>;
};

export type TimelineEvent = {
  ts: number;
  ts_iso: string;
  event: string;
  text?: string;
  author?: string;
  alerts?: { name: string; severity: string; status: string; summary?: string | null; service?: string | null }[];
  draft?: string;
  ok?: boolean;
  model?: string | null;
  latency_ms?: number | null;
  collectors?: Record<string, string>;
  duration_min?: number;
  [k: string]: unknown;
};

export type Incident = IncidentSummary & {
  opened_at: number;
  first_alert_at?: number;
  first_alert_at_iso?: string;
  resolved_at?: number;
  timeline: TimelineEvent[];
  context?: {
    collected_at: string;
    service: string;
    metrics: Record<string, number | null | string>;
    recent_deploys: { kind?: string; text?: string; at_iso?: string; minutes_before_first_alert?: number; note?: string; error?: string }[];
    top_error_reasons: { reason?: string; count?: number; note?: string; error?: string }[];
  };
  context_meta?: Record<string, { ok?: boolean; error?: string; latency_ms?: number }>;
  ai_open_draft?: string;
  ai_hypothesis?: string;
  ai_resolution_draft?: string;
  ai_meta?: Record<string, { ok?: boolean; model?: string; latency_ms?: number; kb_matches?: { id: string; score?: number }[] }>;
};

export type KBEntry = {
  file: string;
  id: string | null;
  title: string | null;
  tier: string | null;
  fix: string | null;
  services: string[];
  symptoms: string[];
  checks: string[];
  learned_from: string[];
  notes: string;
  markdown: string;
  error?: string;
};

// ---- Day 24 ----------------------------------------------------------------------------------
export type KnobValue = { value: string; set: boolean; baseline: string; at_baseline: boolean };
export type KnobTarget = { kind?: string; name?: string; container?: string | null; knobs: Record<string, KnobValue>; error?: string };
export type Scenario = { id: string; title: string; summary: string; file: string };
export type RunStep = {
  n: number; at_seconds: number; action: string; params: Record<string, string>; note: string; state: string;
  ok?: boolean; detail?: string; late_s?: number; fired_at_iso?: string | null; offset_s?: number | null;
};
export type Run = {
  id: string; scenario: string; title?: string; operator: string; status: string; sealed: boolean;
  started_at_iso: string; revealed_at_iso: string | null; reset_at_iso: string | null; ended_at_iso: string | null;
  steps?: RunStep[];
};
export type GameDayState = {
  scenarios: Scenario[];
  scenario_errors: Record<string, string>;
  runs: Run[];
  knobs: Record<string, KnobTarget> | { sealed: true; run: string };
  sealed_run: string | null;
  annotations: boolean;
};
export type KPITile = {
  key: string; title: string; value: number | null; unit: string; trend: (number | null)[]; n?: number | null;
  definition: string; detail: string; second?: (number | null)[]; second_label?: string;
};
export type KPIRow = {
  id: string; service: string | null; severity: string; status: string; alerts: string[];
  opened_at_iso: string; first_alert_at_iso?: string | null; ttd_s: number | null; ttd_source: string | null;
  ttt_s: number | null; duration_min: number | null; closed_by_human: boolean; closed_reason?: string | null;
  remediation: string[]; kb: string | null; kb_id: string | null;
};
export type KPIs = { generated_at: string; weeks: string[]; tiles: KPITile[]; incidents: KPIRow[] };
export type ReportSummary = { day: string; words: number; stored_at_iso: string; model: string | null };
export type Report = ReportSummary & { text: string; data?: unknown };
export type KBFeeding = { incident: string; ts_iso: string; operator: string; decision: "updated" | "not_needed"; kb_id: string | null; reason: string | null };
export type NeedsHuman = {
  kb_unfed: { id: string; service: string | null; resolved_at_iso: string | null }[];
  stale_open: { id: string; service: string | null; alerts: string[]; opened_at_iso: string }[];
  feeding_since_iso: string;
};

export type UIConfig = {
  version: string;
  grafana_url: string;
  splunk_url: string;
  prom_datasource_uid: string;
  embed_panels: { dashboard: string; panel: number; title: string }[];
  metric_queries: Record<string, Record<string, string>>;
  log_reasons_spl: string;
  copilot?: { enabled: boolean; model: string; tool_budget: number; features: Record<string, boolean> };
  repo_url?: string;
  annotations?: boolean;
  dry_run: boolean;
};

export type TrailItem = { id: string; name: string; input: Record<string, unknown>; summary: string; ms: number; error: boolean; result?: string };

export type EvalRow = {
  id: number;
  ts_iso: string;
  operator: string;
  incident: string;
  draft: "open" | "hypothesis" | "resolved" | "copilot" | "report";
  verdict: "up" | "down";
  comment: string | null;
  model?: string | null;
  turn_id?: number | null;
  question?: string | null;
  answer?: string | null;
  trail?: TrailItem[] | null;
  tokens_in?: number | null;
  tokens_out?: number | null;
  cost_usd?: number | null;
  turn_entrance?: string | null;
};

export type ActionResult =
  | { status: "executed" | "failed"; action: string; detail: string; audit_id: number; seconds: number }
  | { status: "pending_approval"; token: string; action: string; blast_radius: string; rationale: string; expires_at_iso: string }
  | { status: string; [k: string]: unknown };
