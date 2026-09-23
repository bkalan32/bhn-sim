// The pending-approvals banner — "This is the Slack button." (PDF Day 22 Step 1).
// Every tier-2 request waits here, whoever asked: you from a button, the remediator on its own,
// the copilot from Day 23. The Approve click IS the second click; the API refuses it from the
// copilot or MCP entrances by construction (HUMAN_ENTRANCES in app.py).
import { useActions, useApprovals, useDecide } from "../lib/queries";
import { ago, params, utcTime } from "../lib/format";
import { href } from "../lib/router";
import type { Approval } from "../lib/types";
import { Button, Badge } from "./ui";

export function ApprovalCard({ a, compact = false }: { a: Approval; compact?: boolean }) {
  const { data: catalog } = useActions();
  const decide = useDecide();
  const entry = catalog?.find((c) => c.id === a.action);
  const busy = decide.isPending && decide.variables?.token === a.token;
  return (
    <div className="flex flex-wrap items-start justify-between gap-3 rounded-md border border-warning/60 bg-surface-3 p-3">
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-2">
          <span className="font-semibold text-ink">{entry?.title ?? a.action}</span>
          <code className="font-mono text-xs text-ink-2">{params(a.params)}</code>
          <Badge tone="warning">tier 2</Badge>
          {a.incident && (
            <a className="text-xs text-info hover:underline" href={href("incidents", a.incident)}>
              {a.incident}
            </a>
          )}
        </div>
        <p className="mt-1 text-xs text-ink-3">
          asked by <span className="text-ink-2">{a.operator}</span> via {a.entrance} · {ago(a.created_at_iso)} · expires{" "}
          {utcTime(a.expires_at_iso)}
        </p>
        {a.reason && <p className="mt-1 text-sm text-ink-2">“{a.reason}”</p>}
        {!compact && entry && (
          <dl className="mt-2 grid gap-x-4 gap-y-1 text-xs sm:grid-cols-[auto_1fr]">
            <dt className="text-ink-3">Blast radius</dt>
            <dd className="text-ink-2">{entry.blast_radius}</dd>
            <dt className="text-ink-3">Why tier 2</dt>
            <dd className="text-ink-2">{entry.rationale}</dd>
          </dl>
        )}
      </div>
      <div className="flex shrink-0 gap-2">
        <Button variant="primary" size="sm" disabled={busy} onClick={() => decide.mutate({ token: a.token, approve: true })}>
          {busy && decide.variables?.approve ? "Approving…" : "Approve"}
        </Button>
        <Button variant="secondary" size="sm" disabled={busy} onClick={() => decide.mutate({ token: a.token, approve: false })}>
          Decline
        </Button>
      </div>
    </div>
  );
}

export function ApprovalBanner() {
  const { data, isError } = useApprovals();
  if (isError || !data || data.length === 0) return null;
  return (
    <div role="region" aria-label="Pending approvals" className="border-b border-warning/60 bg-warning/10 px-4 py-3 sm:px-6">
      <p className="mb-2 text-sm font-semibold text-ink">
        <span aria-hidden>⚠ </span>
        {data.length} action{data.length > 1 ? "s" : ""} waiting for a human
      </p>
      <div className="flex flex-col gap-2">
        {data.map((a) => (
          <ApprovalCard key={a.token} a={a} />
        ))}
      </div>
    </div>
  );
}
