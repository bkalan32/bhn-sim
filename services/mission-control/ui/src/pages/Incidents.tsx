// Day 22 Step 2 — the list: open first, then resolved; filter by service and severity.
import { useMemo, useState } from "react";
import { useIncidents } from "../lib/queries";
import { duration, severityTone, utcDateTime } from "../lib/format";
import { href } from "../lib/router";
import { Badge, Card, Skeleton, Status, Unavailable } from "../components/ui";

export function Incidents() {
  const { data, isLoading, error } = useIncidents();
  const [service, setService] = useState("all");
  const [severity, setSeverity] = useState("all");
  const [status, setStatus] = useState("all");

  const services = useMemo(() => [...new Set((data ?? []).map((i) => i.service ?? "?"))].sort(), [data]);
  const rows = useMemo(() => {
    const list = (data ?? []).filter(
      (i) =>
        (service === "all" || (i.service ?? "?") === service) &&
        (severity === "all" || i.severity === severity) &&
        (status === "all" || i.status === status),
    );
    return list.sort((a, b) =>
      a.status !== b.status ? (a.status === "open" ? -1 : 1) : (b.opened_at_iso ?? "").localeCompare(a.opened_at_iso ?? ""),
    );
  }, [data, service, severity, status]);

  return (
    <Card
      title={`Incidents${data ? ` · ${data.filter((i) => i.status === "open").length} open of ${data.length}` : ""}`}
      actions={
        <div className="flex flex-wrap gap-2 text-xs">
          <Select label="Status" value={status} set={setStatus} options={["all", "open", "resolved"]} />
          <Select label="Service" value={service} set={setService} options={["all", ...services]} />
          <Select label="Severity" value={severity} set={setSeverity} options={["all", "critical", "warning", "none"]} />
        </div>
      }
    >
      {isLoading && <Skeleton className="h-40" />}
      {error && <Unavailable what="incidents" error={String(error)} />}
      {data && (
        <div className="overflow-x-auto">
          <table className="w-full min-w-[720px] text-left text-sm">
            <thead className="text-xs text-ink-3">
              <tr className="border-b border-line">
                <th className="py-2 pr-3 font-medium">Incident</th>
                <th className="py-2 pr-3 font-medium">Status</th>
                <th className="py-2 pr-3 font-medium">Severity</th>
                <th className="py-2 pr-3 font-medium">Service</th>
                <th className="py-2 pr-3 font-medium">Opened</th>
                <th className="py-2 pr-3 font-medium">Duration</th>
                <th className="py-2 font-medium">Alerts</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((i) => (
                <tr key={i.id} className="border-b border-line/60 hover:bg-surface-3">
                  <td className="py-2 pr-3">
                    <a className="font-mono text-info hover:underline" href={href("incidents", i.id)}>
                      {i.id}
                    </a>
                  </td>
                  <td className="py-2 pr-3">
                    <Status tone={i.status === "open" ? "warning" : "good"} label={i.status} />
                  </td>
                  <td className="py-2 pr-3">
                    <Badge tone={severityTone(i.severity)}>{i.severity}</Badge>
                  </td>
                  <td className="py-2 pr-3">{i.service ?? "—"}</td>
                  <td className="tabular py-2 pr-3 font-mono text-xs text-ink-2">{utcDateTime(i.opened_at_iso)}</td>
                  <td className="tabular py-2 pr-3 text-ink-2">
                    {i.duration_min != null ? duration(i.duration_min * 60) : duration((Date.now() - new Date(i.opened_at_iso).getTime()) / 1000) + " (open)"}
                  </td>
                  <td className="py-2 text-xs text-ink-2">{(i.alerts ?? []).join(", ")}</td>
                </tr>
              ))}
              {rows.length === 0 && (
                <tr>
                  <td colSpan={7} className="py-6 text-center text-ink-3">
                    No incidents match.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  );
}

function Select({ label, value, set, options }: { label: string; value: string; set: (v: string) => void; options: string[] }) {
  return (
    <label className="inline-flex items-center gap-1 text-ink-3">
      {label}
      <select className="rounded border border-line bg-surface px-1.5 py-1 text-ink" value={value} onChange={(e) => set(e.target.value)}>
        {options.map((o) => (
          <option key={o} value={o}>
            {o}
          </option>
        ))}
      </select>
    </label>
  );
}
