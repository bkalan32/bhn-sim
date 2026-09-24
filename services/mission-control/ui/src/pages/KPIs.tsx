// Day 24 Step 2 — the seven Day 18 KPIs (docs/ops-kpis.md) as tiles: this week's value, a 4-week trend,
// the definition in the tooltip (and one click away), and the incident table they are computed from.
// MTTD is computed from the game-day console's injection times now — the "caused by" column says so.
import { useMemo, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { api } from "../lib/api";
import { useKPIs } from "../lib/queries";
import { href } from "../lib/router";
import { utcDateTime } from "../lib/format";
import type { KPIRow, KPITile, KPIs as KPIData } from "../lib/types";
import { Badge, Button, Card, Skeleton, Unavailable, cx } from "../components/ui";

const fmt = (v: number | null | undefined, unit: string) => {
  if (v == null) return "—";
  if (unit === "s") return v >= 120 ? `${(v / 60).toFixed(1)} min` : `${Math.round(v)} s`;
  if (unit === "min") return `${v.toFixed(1)} min`;
  if (unit === "%") return `${v.toFixed(v >= 10 ? 0 : 1)} %`;
  if (unit === "/day") return `${v}`;
  return `${v}`;
};

export function KPIs() {
  const { data, isLoading, error } = useKPIs();
  const qc = useQueryClient();
  const [busy, setBusy] = useState(false);
  const recompute = () => {
    setBusy(true);
    api<KPIData>("/api/kpis?fresh=true").then((d) => qc.setQueryData(["kpis"], d)).finally(() => setBusy(false));
  };
  if (isLoading) return <Skeleton className="h-96" />;
  if (error || !data) return <Unavailable what="KPIs" error={String(error)} />;
  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-center justify-between text-xs text-ink-3">
        <span>
          Weeks starting {data.weeks.join(" · ")} — computed {utcDateTime(data.generated_at)} from the incident records, the
          game-day runs, the remediator, Jenkins and Prometheus.
        </span>
        <Button size="sm" variant="ghost" disabled={busy} onClick={recompute}>
          {busy ? "…" : "Recompute"}
        </Button>
      </div>
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        {data.tiles.map((t) => (
          <Tile key={t.key} t={t} weeks={data.weeks} />
        ))}
      </div>
      <IncidentTable rows={data.incidents} />
    </div>
  );
}

function Tile({ t, weeks }: { t: KPITile; weeks: string[] }) {
  const [info, setInfo] = useState(false);
  return (
    <section className="rounded-lg border border-line bg-surface-2 p-3" title={t.definition}>
      <div className="flex items-start justify-between gap-2">
        <h3 className="text-xs text-ink-3">{t.title}</h3>
        <button className="text-[11px] text-info hover:underline" onClick={() => setInfo((i) => !i)} aria-expanded={info}>
          {info ? "hide" : "definition"}
        </button>
      </div>
      <p className="tabular mt-0.5 text-2xl font-semibold">
        {fmt(t.value, t.unit)}
        {t.second && <span className="ml-2 text-sm font-normal text-ink-3">{t.second_label}: {fmt(t.second[t.second.length - 1], "%")}</span>}
      </p>
      <Trend values={t.trend} unit={t.unit} weeks={weeks} />
      {t.detail && <p className="mt-1 text-[11px] text-ink-3">{t.detail}</p>}
      {info && <p className="mt-2 border-t border-line pt-2 text-xs text-ink-2">{t.definition}</p>}
    </section>
  );
}

/** Four weeks, oldest left. A missing week is a gap with a dash, not a zero. */
function Trend({ values, unit, weeks }: { values: (number | null)[]; unit: string; weeks: string[] }) {
  const max = Math.max(1, ...values.map((v) => v ?? 0));
  return (
    <div className="mt-2 flex h-14 items-end gap-1.5" aria-label="4-week trend">
      {values.map((v, i) => (
        <div key={i} className="flex flex-1 flex-col items-center gap-0.5" title={`week of ${weeks[i]}: ${fmt(v, unit)}`}>
          <span className="tabular text-[10px] text-ink-3">{v == null ? "—" : fmt(v, unit)}</span>
          <div className={cx("w-full rounded-sm", v == null ? "h-px bg-line" : i === values.length - 1 ? "bg-info" : "bg-info/40")}
            style={v == null ? undefined : { height: `${Math.max(3, (v / max) * 28)}px` }} />
        </div>
      ))}
    </div>
  );
}

type SortKey = "opened_at_iso" | "service" | "ttd_s" | "ttt_s" | "duration_min";

function IncidentTable({ rows }: { rows: KPIRow[] }) {
  const [sort, setSort] = useState<{ key: SortKey; dir: 1 | -1 }>({ key: "opened_at_iso", dir: -1 });
  const [onlyMeasured, setOnlyMeasured] = useState(false);
  const sorted = useMemo(() => {
    const r = rows.filter((x) => !onlyMeasured || x.ttd_s != null);
    return [...r].sort((a, b) => {
      const va = a[sort.key], vb = b[sort.key];
      if (va == null && vb == null) return 0;
      if (va == null) return 1;
      if (vb == null) return -1;
      return (va < vb ? -1 : va > vb ? 1 : 0) * sort.dir;
    });
  }, [rows, sort, onlyMeasured]);
  const th = (key: SortKey, label: string) => (
    <th className="pb-2 font-normal">
      <button className="hover:text-ink" onClick={() => setSort((s) => ({ key, dir: s.key === key ? (-s.dir as 1 | -1) : -1 }))}>
        {label}
        {sort.key === key ? (sort.dir === 1 ? " ▲" : " ▼") : ""}
      </button>
    </th>
  );
  return (
    <Card
      title={`Incidents · ${rows.length}`}
      actions={
        <label className="flex items-center gap-1 text-xs text-ink-3">
          <input type="checkbox" checked={onlyMeasured} onChange={(e) => setOnlyMeasured(e.target.checked)} /> only with a measured MTTD
        </label>
      }
    >
      <div className="overflow-x-auto">
        <table className="w-full text-xs">
          <thead>
            <tr className="text-left text-ink-3">
              <th className="pb-2 font-normal">Incident</th>
              {th("service", "Service")}
              <th className="pb-2 font-normal">Alerts</th>
              {th("opened_at_iso", "Opened (UTC)")}
              {th("ttd_s", "MTTD")}
              <th className="pb-2 font-normal">Caused by</th>
              {th("ttt_s", "Alert → ticket")}
              {th("duration_min", "Duration")}
              <th className="pb-2 font-normal">Remediation</th>
              <th className="pb-2 font-normal">KB</th>
            </tr>
          </thead>
          <tbody>
            {sorted.map((r) => (
              <tr key={r.id} className="border-t border-line/50 align-top">
                <td className="py-1.5 pr-2"><a className="font-mono text-info hover:underline" href={href("incidents", r.id)}>{r.id}</a></td>
                <td className="py-1.5 pr-2">{r.service}</td>
                <td className="py-1.5 pr-2 text-ink-2">{r.alerts.join(", ")}</td>
                <td className="tabular py-1.5 pr-2 font-mono">{(r.opened_at_iso || "").replace("T", " ").slice(0, 16)}</td>
                <td className="tabular py-1.5 pr-2 font-semibold">{r.ttd_s == null ? "—" : `${r.ttd_s} s`}</td>
                <td className="py-1.5 pr-2 text-ink-3">{r.ttd_source ?? ""}</td>
                <td className="tabular py-1.5 pr-2">{r.ttt_s == null ? "—" : `${r.ttt_s} s`}</td>
                <td className="tabular py-1.5 pr-2">
                  {r.duration_min == null ? (r.status === "open" ? "open" : "—") : `${r.duration_min} min`}
                  {r.closed_by_human && <Badge className="ml-1" tone="neutral">closed by hand</Badge>}
                </td>
                <td className="py-1.5 pr-2 text-ink-3">{r.remediation.join(", ")}</td>
                <td className="py-1.5">{r.kb === "updated" ? <Badge tone="good">{r.kb_id}</Badge> : r.kb === "not_needed" ? <Badge>not needed</Badge> : ""}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="mt-3 text-[11px] text-ink-3">
        "Closed by hand" durations are how long nobody noticed a lost webhook, not an outage — MTTR leaves them out.
      </p>
    </Card>
  );
}
