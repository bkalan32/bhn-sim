// "What has anyone done to this platform in the last hour?" must be one glance (PDF Day 21 Step 4).
import type { AuditRow } from "../lib/types";
import { params, utcTime, type Tone } from "../lib/format";
import { href } from "../lib/router";
import { Status } from "./ui";

const RESULT_TONE: Record<string, Tone> = { ok: "good", pending: "warning", failed: "critical", refused: "critical", rejected: "critical", declined: "neutral", expired: "neutral" };

export function AuditTable({ rows }: { rows: AuditRow[] }) {
  if (!rows.length) return <p className="text-sm text-ink-3">Nothing has been done through Mission Control yet.</p>;
  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[640px] text-left text-sm">
        <thead className="text-xs text-ink-3">
          <tr className="border-b border-line">
            <th className="py-1.5 pr-3 font-medium">Time</th>
            <th className="py-1.5 pr-3 font-medium">Who</th>
            <th className="py-1.5 pr-3 font-medium">Action</th>
            <th className="py-1.5 pr-3 font-medium">Tier · via</th>
            <th className="py-1.5 pr-3 font-medium">Result</th>
            <th className="py-1.5 font-medium">Parameters</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => {
            const inc = typeof r.params?.incident === "string" ? (r.params.incident as string) : null;
            return (
              <tr key={r.id} className="border-b border-line/60 align-top">
                <td className="tabular py-1.5 pr-3 font-mono text-xs text-ink-2">{utcTime(r.ts_iso)}</td>
                <td className="py-1.5 pr-3">{r.operator}</td>
                <td className="py-1.5 pr-3 font-medium">{r.action}</td>
                <td className="py-1.5 pr-3 text-xs text-ink-2">
                  t{r.tier} · {r.entrance}
                </td>
                <td className="py-1.5 pr-3">
                  <Status tone={RESULT_TONE[r.result] ?? "neutral"} label={r.result} />
                </td>
                <td className="py-1.5 font-mono text-xs text-ink-2">
                  {inc ? (
                    <a className="text-info hover:underline" href={href("incidents", inc)}>
                      {params(r.params)}
                    </a>
                  ) : (
                    params(r.params) || "—"
                  )}
                  {r.approval_token && <span className="block text-ink-3">token {r.approval_token}</span>}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
