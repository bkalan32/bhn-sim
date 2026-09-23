// Small, boring formatting helpers. Times are shown in UTC everywhere — the incident records,
// Alertmanager and the audit log are all UTC, and a console that mixes zones mid-incident
// produces wrong timelines.

export function utcTime(iso?: string | null): string {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toISOString().slice(11, 19) + "Z";
}

export function utcDateTime(iso?: string | null): string {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toISOString().slice(0, 16).replace("T", " ") + "Z";
}

export function ago(iso?: string | null, now = Date.now()): string {
  if (!iso) return "—";
  const t = new Date(iso).getTime();
  if (Number.isNaN(t)) return "—";
  return duration((now - t) / 1000) + " ago";
}

export function duration(seconds: number | null | undefined): string {
  if (seconds === null || seconds === undefined || !Number.isFinite(seconds)) return "—";
  const s = Math.max(0, Math.round(seconds));
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${String(s % 60).padStart(2, "0")}s`;
  const h = Math.floor(m / 60);
  return `${h}h ${String(m % 60).padStart(2, "0")}m`;
}

export function num(v: unknown, digits = 1): string {
  if (typeof v !== "number" || !Number.isFinite(v)) return v === null || v === undefined ? "—" : String(v);
  return v.toFixed(digits);
}

export function params(p: Record<string, unknown> | null | undefined): string {
  if (!p) return "";
  return Object.entries(p)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([k, v]) => `${k}=${String(v)}`)
    .join(" ");
}

// Health thresholds — docs/health-score.md "Thresholds on the overview" (Day 7).
export type Tone = "good" | "warning" | "critical" | "neutral" | "info";

export function healthTone(score: number | undefined): Tone {
  if (score === undefined || !Number.isFinite(score)) return "neutral";
  if (score >= 90) return "good";
  if (score >= 70) return "warning";
  return "critical";
}

export function healthLabel(score: number | undefined): string {
  const t = healthTone(score);
  return t === "good" ? "Meeting SLOs" : t === "warning" ? "Over budget" : t === "critical" ? "Incident territory" : "No data";
}

export function severityTone(sev?: string | null): Tone {
  if (sev === "critical") return "critical";
  if (sev === "warning") return "warning";
  return "neutral";
}
