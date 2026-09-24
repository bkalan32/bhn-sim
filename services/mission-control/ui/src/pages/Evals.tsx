// docs/ai-eval.md as a table (PDF Day 23 Step 2): every grade anyone gave an AI output — a draft on an
// incident page, or a copilot answer with its question, tool trail, tokens and cost. The discipline
// from Days 9-11 now costs one click, which is the only way it survives a busy week.
import { useMemo, useState } from "react";
import { useEvalRows } from "../lib/queries";
import { utcDateTime } from "../lib/format";
import { href } from "../lib/router";
import type { EvalRow } from "../lib/types";
import { Badge, Card, Skeleton, Status, Unavailable } from "../components/ui";

export function Evals() {
  const { data, isLoading, error } = useEvalRows();
  const [kind, setKind] = useState("all");
  const rows = useMemo(() => (data ?? []).filter((r) => kind === "all" || (kind === "copilot" ? r.draft === "copilot" : kind === "reports" ? r.draft === "report" : r.draft !== "copilot" && r.draft !== "report")), [data, kind]);
  const stats = useMemo(() => {
    const by = (f: (r: EvalRow) => boolean) => {
      const s = (data ?? []).filter(f);
      const up = s.filter((r) => r.verdict === "up").length;
      return { n: s.length, up, pct: s.length ? Math.round((100 * up) / s.length) : null };
    };
    const cost = (data ?? []).reduce((a, r) => a + (r.cost_usd ?? 0), 0);
    return { copilot: by((r) => r.draft === "copilot"), drafts: by((r) => r.draft !== "copilot" && r.draft !== "report"), cost };
  }, [data]);

  return (
    <div className="flex flex-col gap-4">
      <div className="grid gap-3 sm:grid-cols-3">
        <Stat label="Copilot answers graded" s={stats.copilot} />
        <Stat label="Incident drafts graded" s={stats.drafts} />
        <div className="rounded-lg border border-line bg-surface-2 p-3">
          <h3 className="text-xs text-ink-3">Model cost of the graded copilot answers</h3>
          <p className="tabular mt-0.5 text-2xl font-semibold">${stats.cost.toFixed(4)}</p>
        </div>
      </div>
      <Card
        title={`Evaluations${data ? ` · ${data.length}` : ""}`}
        actions={
          <select className="rounded border border-line bg-surface px-1.5 py-1 text-xs text-ink" value={kind} onChange={(e) => setKind(e.target.value)}>
            <option value="all">all</option>
            <option value="copilot">copilot answers</option>
            <option value="drafts">incident drafts</option>
            <option value="reports">daily reports</option>
          </select>
        }
      >
        {isLoading && <Skeleton className="h-40" />}
        {error && <Unavailable what="evals" error={String(error)} />}
        {data && rows.length === 0 && <p className="text-sm text-ink-3">Nothing graded yet — 👍/👎 under a copilot answer or an incident draft.</p>}
        <ul className="divide-y divide-line/60">
          {rows.map((r) => (
            <EvalItem key={r.id} r={r} />
          ))}
        </ul>
      </Card>
    </div>
  );
}

function Stat({ label, s }: { label: string; s: { n: number; up: number; pct: number | null } }) {
  return (
    <div className="rounded-lg border border-line bg-surface-2 p-3">
      <h3 className="text-xs text-ink-3">{label}</h3>
      <p className="tabular mt-0.5 text-2xl font-semibold">{s.n}</p>
      <p className="text-xs text-ink-3">{s.pct == null ? "—" : `${s.pct}% 👍 (${s.up} of ${s.n})`}</p>
    </div>
  );
}

function EvalItem({ r }: { r: EvalRow }) {
  const [open, setOpen] = useState(false);
  return (
    <li className="py-3 text-sm">
      <div className="flex flex-wrap items-center gap-2">
        <Status tone={r.verdict === "up" ? "good" : "critical"} label={r.verdict === "up" ? "good" : "wrong"} />
        <Badge>{r.draft === "copilot" ? `copilot${r.turn_entrance && r.turn_entrance !== "copilot" ? ` (${r.turn_entrance})` : ""}` : r.draft === "report" ? "daily report" : `${r.draft} draft`}</Badge>
        {r.draft === "report" && <a href={href("reports")} className="font-mono text-xs text-info hover:underline">{r.incident.replace("report:", "")}</a>}
        {r.incident && r.incident !== "-" && r.draft !== "report" && (
          <a href={href("incidents", r.incident)} className="font-mono text-xs text-info hover:underline">{r.incident}</a>
        )}
        <span className="tabular font-mono text-xs text-ink-3">{utcDateTime(r.ts_iso)}</span>
        <span className="text-xs text-ink-3">by {r.operator}</span>
        {r.model && <span className="text-xs text-ink-3">· {r.model}</span>}
        {r.cost_usd != null && <span className="text-xs text-ink-3">· {r.tokens_in}→{r.tokens_out} tok · ${r.cost_usd.toFixed(4)}</span>}
      </div>
      {r.question && <p className="mt-1 text-ink">“{r.question}”</p>}
      {r.comment && <p className="mt-1 text-ink-2">Note: {r.comment}</p>}
      {r.draft === "copilot" && (
        <button onClick={() => setOpen((o) => !o)} className="mt-1 text-xs text-info hover:underline">
          {open ? "hide" : `answer and ${r.trail?.length ?? 0} tool call${r.trail?.length === 1 ? "" : "s"}`}
        </button>
      )}
      {open && (
        <div className="mt-2 grid gap-2 lg:grid-cols-2">
          <pre className="max-h-72 overflow-auto whitespace-pre-wrap rounded-md border border-line bg-surface p-2 text-xs text-ink-2">{r.answer}</pre>
          <ol className="space-y-1 text-xs">
            {(r.trail ?? []).map((t) => (
              <li key={t.id} className="rounded border border-line bg-surface p-2">
                <span className="font-mono font-semibold">{t.name}</span>{" "}
                <code className="break-all font-mono text-[11px] text-ink-2">{JSON.stringify(t.input)}</code>
                <span className="block text-ink-3">→ {t.summary}</span>
              </li>
            ))}
          </ol>
        </div>
      )}
    </li>
  );
}
