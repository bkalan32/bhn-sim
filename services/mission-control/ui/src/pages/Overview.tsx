// Day 22 Step 1 — the ten-second screen. Day 7's Platform Overview as a live page: the numbers
// that decide "is anything wrong", the feed, the Grafana panels (embedded, not rebuilt), and the
// last ten things anyone did.
import type { ReactNode } from "react";
import { useAudit, useConfig, useOverview } from "../lib/queries";
import { duration, healthLabel, healthTone, num, type Tone } from "../lib/format";
import { dashboardUrl, panelUrl, SERVICE_DASHBOARD } from "../lib/links";
import { href } from "../lib/router";
import type { Part } from "../lib/types";
import { Sparkline } from "../components/sparkline";
import { Feed } from "../components/feed";
import { AuditTable } from "../components/audit";
import { Card, ExtLink, Skeleton, Status, Unavailable, accent, cx } from "../components/ui";

function partData<T>(p: Part<T> | undefined): T | undefined {
  return p && p.ok ? p.data : undefined;
}

export function Overview() {
  const { data: ov, isLoading, error } = useOverview();
  const { data: cfg } = useConfig();
  const { data: audit } = useAudit(10);

  const health = partData(ov?.health) ?? {};
  const spark = partData(ov?.sparklines) ?? {};
  const alerts = partData(ov?.alerts) ?? [];
  const critical = alerts.filter((a) => a.severity === "critical");
  const incidents = partData(ov?.incidents) ?? [];
  const deploys = partData(ov?.deploys_today);
  const settlementAge = partData(ov?.settlement_age_s);
  const traffic = partData(ov?.traffic);

  return (
    <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_360px]">
      <div className="flex min-w-0 flex-col gap-4">
        {error && <Unavailable what="Overview" error={String(error)} />}
        {/* ---- top strip ---- */}
        <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
          <ScoreTile big name="Platform health" score={health.platform} series={spark.platform ?? []} loading={isLoading} part={ov?.health} />
          {(["activation", "egift", "settlement"] as const).map((s) => (
            <ScoreTile
              key={s}
              name={s}
              score={health[s]}
              series={spark[s] ?? []}
              loading={isLoading}
              part={ov?.health}
              link={cfg && SERVICE_DASHBOARD[s] ? dashboardUrl(cfg, SERVICE_DASHBOARD[s]) : undefined}
            />
          ))}
        </div>
        <div className="grid grid-cols-2 gap-3 xl:grid-cols-4">
          <Stat label="Critical alerts firing" tone={critical.length ? "critical" : "good"} part={ov?.alerts} loading={isLoading}
            value={String(critical.length)} sub={alerts.length - critical.length ? `+ ${alerts.length - critical.length} warning` : "no warnings"} />
          <Stat label="Open incidents" tone={incidents.length ? "warning" : "good"} part={ov?.incidents} loading={isLoading}
            value={String(incidents.length)} sub={<a className="text-info hover:underline" href={href("incidents")}>open the list</a>} />
          <Stat label="Deploys today (UTC)" tone="neutral" part={ov?.deploys_today} loading={isLoading} value={deploys ? String(deploys.length) : "—"}
            sub={deploys?.[0]?.text ? String(deploys[0].text).slice(0, 48) : "pipeline annotations"} />
          <Stat label="Last settlement" tone={settlementAge == null ? "neutral" : settlementAge > 900 ? "critical" : "good"} part={ov?.settlement_age_s}
            loading={isLoading} value={settlementAge == null ? "—" : duration(settlementAge)} sub={settlementAge != null && settlementAge > 900 ? "over 15 min — scored 0" : "ago"} />
        </div>

        {traffic && (
          <p className="text-xs text-ink-3">
            Traffic (loadgen, 2 m):{" "}
            {Object.entries(traffic.rps).map(([t, r]) => (
              <span key={t} className="mr-3 text-ink-2">
                {t} <span className="tabular font-mono">{num(r, 2)}</span> req/s
                {traffic.multiplier[t] !== undefined && traffic.multiplier[t] !== 1 && (
                  <span className="text-warning"> · ×{traffic.multiplier[t]}{traffic.multiplier[t] === 0 ? " (turned off)" : ""}</span>
                )}
              </span>
            ))}
            {ov && <span className="ml-2">· overview built in {ov.ms} ms</span>}
          </p>
        )}

        {/* ---- live feed, on narrow screens ---- */}
        <Feed className="h-80 lg:hidden" />

        {/* ---- embedded Grafana ---- */}
        <Card title="Golden signals — Grafana (dashboards as code, embedded)"
          actions={cfg && <ExtLink href={dashboardUrl(cfg, "bhn-overview")} className="text-xs">Platform Overview</ExtLink>}>
          {!cfg ? (
            <Skeleton className="h-56" />
          ) : (
            <>
              <div className="grid gap-3 md:grid-cols-2">
                {cfg.embed_panels.map((p) => (
                  <figure key={`${p.dashboard}-${p.panel}`} className="overflow-hidden rounded-md border border-line bg-surface">
                    <iframe title={p.title} src={panelUrl(cfg, p.dashboard, p.panel)} loading="lazy" className="block h-56 w-full border-0" />
                  </figure>
                ))}
              </div>
              <p className="mt-2 text-[11px] text-ink-3">
                Panels load from {cfg.grafana_url}. Blank frames mean that port-forward is not running — <code>./scripts/220-mc-open.sh</code> starts it.
              </p>
            </>
          )}
        </Card>

        <Card title="Last ten actions (audit log)" actions={<a className="text-xs text-info hover:underline" href={href("audit")}>all</a>}>
          {audit ? <AuditTable rows={audit} /> : <Skeleton className="h-24" />}
        </Card>
      </div>

      <Feed className="sticky top-4 hidden h-[calc(100vh-7rem)] lg:flex" />
    </div>
  );
}

function ScoreTile({ name, score, series, big, loading, part, link }: {
  name: string; score?: number; series: number[]; big?: boolean; loading: boolean; part?: Part<unknown>; link?: string;
}) {
  const tone = healthTone(score);
  return (
    <div className={cx("rounded-lg bg-surface-2 p-3", accent(tone))}>
      <div className="flex items-baseline justify-between gap-2">
        <h3 className="text-xs font-semibold uppercase tracking-wider text-ink-3">{name}</h3>
        {link && <ExtLink href={link} className="text-[11px]">dashboard</ExtLink>}
      </div>
      {loading ? (
        <Skeleton className="mt-2 h-12" />
      ) : part && !part.ok ? (
        <Unavailable what="score" error={part.error} />
      ) : (
        <>
          <div className="mt-1 flex items-baseline gap-3">
            <span className={cx("tabular font-semibold text-ink", big ? "text-5xl" : "text-3xl")}>{score === undefined ? "—" : score.toFixed(1)}</span>
            <Status tone={tone} label={healthLabel(score)} />
          </div>
          <Sparkline values={series} label={`${name} health`} />
        </>
      )}
    </div>
  );
}

function Stat({ label, value, sub, tone, part, loading }: {
  label: string; value: string; sub?: ReactNode; tone: Tone; part?: Part<unknown>; loading: boolean;
}) {
  return (
    <div className={cx("rounded-lg bg-surface-2 p-3", accent(tone))}>
      <h3 className="text-xs text-ink-3">{label}</h3>
      {loading ? (
        <Skeleton className="mt-1 h-8" />
      ) : part && !part.ok ? (
        <Unavailable what={label} error={part.error} />
      ) : (
        <>
          <p className="tabular mt-0.5 text-2xl font-semibold">{value}</p>
          {sub && <p className="truncate text-xs text-ink-3">{sub}</p>}
        </>
      )}
    </div>
  );
}
