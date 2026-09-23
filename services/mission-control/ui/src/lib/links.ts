// Deep links out of the console. Mission Control does not rebuild the specialist tools
// (PDF "Do not build"): a number links to the PromQL that produced it in Grafana Explore, a log
// histogram links to the SPL in Splunk, a panel is an iframe of the dashboard-as-code.
import type { UIConfig } from "./types";

export function exploreUrl(cfg: UIConfig, expr: string, fromMs?: number, toMs?: number): string {
  const pane = {
    datasource: cfg.prom_datasource_uid,
    queries: [{ refId: "A", expr, datasource: { type: "prometheus", uid: cfg.prom_datasource_uid } }],
    range: { from: fromMs ? String(fromMs) : "now-1h", to: toMs ? String(toMs) : "now" },
  };
  return `${cfg.grafana_url}/explore?schemaVersion=1&orgId=1&panes=${encodeURIComponent(JSON.stringify({ mc: pane }))}`;
}

export function splunkUrl(cfg: UIConfig, spl: string, earliestS?: number, latestS?: number): string {
  const q = new URLSearchParams({
    q: `search ${spl}`,
    earliest: earliestS ? String(Math.floor(earliestS)) : "-60m",
    latest: latestS ? String(Math.ceil(latestS)) : "now",
  });
  return `${cfg.splunk_url}/en-US/app/search/search?${q.toString()}`;
}

export function panelUrl(cfg: UIConfig, dashboard: string, panel: number, from = "now-1h", to = "now"): string {
  const q = new URLSearchParams({ orgId: "1", panelId: String(panel), from, to, refresh: "30s", theme: "dark" });
  // A slug is required by some Grafana versions' routes and ignored by all: "panel" is fine.
  return `${cfg.grafana_url}/d-solo/${encodeURIComponent(dashboard)}/panel?${q.toString()}`;
}

export function dashboardUrl(cfg: UIConfig, dashboard: string, fromMs?: number, toMs?: number): string {
  const q = new URLSearchParams({ orgId: "1", from: fromMs ? String(fromMs) : "now-6h", to: toMs ? String(toMs) : "now" });
  return `${cfg.grafana_url}/d/${encodeURIComponent(dashboard)}?${q.toString()}`;
}

export const SERVICE_DASHBOARD: Record<string, string> = {
  activation: "bhn-activation",
  egift: "bhn-egift",
};
