// A catalog entry as a button. Tier 1 runs on click. Tier 2 opens the confirmation card —
// rationale, blast radius, the parameters, a reason — and its button REQUESTS the action; the
// request then waits in the approvals banner for a human's Approve. Same catalog entry, same
// validation, same audit row as `tools/mc.py run`, the command palette and the copilot's proposals.
import { useState } from "react";
import type { Entrance } from "../lib/api";
import { useRunAction } from "../lib/queries";
import type { Action } from "../lib/types";
import { Button, TierBadge } from "./ui";

export function ActionButton({ action, fixed = {}, label }: { action: Action; fixed?: Record<string, unknown>; label?: string }) {
  const run = useRunAction("button");
  const [open, setOpen] = useState(false);
  const busy = run.isPending;

  if (action.tier === 1 && action.params.every((p) => p in fixed)) {
    return (
      <Button size="sm" disabled={busy} onClick={() => run.mutate({ id: action.id, params: fixed })} title={action.rationale}>
        {busy ? "Running…" : label ?? action.title}
      </Button>
    );
  }
  return (
    <>
      <Button size="sm" variant={open ? "ghost" : "secondary"} onClick={() => setOpen((o) => !o)} aria-expanded={open}>
        {label ?? action.title}…
      </Button>
      {open && <ConfirmCard action={action} fixed={fixed} onClose={() => setOpen(false)} />}
    </>
  );
}

/** The confirmation card. Tier 2: "Request — needs approval". Tier 1 with parameters to fill: "Run". */
export function ConfirmCard({ action, fixed = {}, onClose, entrance = "button", reasonDefault = "", autoFocus = false }: {
  action: Action; fixed?: Record<string, unknown>; onClose: () => void; entrance?: Entrance; reasonDefault?: string; autoFocus?: boolean;
}) {
  const run = useRunAction(entrance);
  const free = action.params.filter((p) => !(p in fixed));
  const [values, setValues] = useState<Record<string, string>>({});
  const [reason, setReason] = useState(reasonDefault);
  const all = { ...fixed, ...values };
  const tier2 = action.tier === 2;
  const ready = free.every((p) => (values[p] ?? "").trim() !== "") && (!tier2 || reason.trim().length >= 3);
  const submit = () => run.mutate({ id: action.id, params: all, reason }, { onSuccess: onClose });

  return (
    <form
      className="mt-2 w-full rounded-md border border-warning/60 bg-surface-3 p-3 text-sm"
      onSubmit={(e) => {
        e.preventDefault();
        if (ready && !run.isPending) submit();
      }}
    >
      <div className="flex items-center gap-2">
        <span className="font-semibold">{action.title}</span>
        <TierBadge tier={action.tier} />
      </div>
      <dl className="mt-2 grid gap-x-4 gap-y-1 text-xs sm:grid-cols-[auto_1fr]">
        <dt className="text-ink-3">Blast radius</dt>
        <dd className="text-ink-2">{action.blast_radius}</dd>
        <dt className="text-ink-3">Why tier {action.tier}</dt>
        <dd className="text-ink-2">{action.rationale}</dd>
        {Object.entries(fixed).map(([k, v]) => (
          <FixedParam key={k} k={k} v={v} />
        ))}
      </dl>
      {free.map((p, i) => (
        <label key={p} className="mt-2 block text-xs text-ink-3">
          {p}
          <input
            autoFocus={autoFocus && i === 0}
            className="mt-1 block w-full rounded border border-line bg-surface px-2 py-1 font-mono text-sm text-ink"
            value={values[p] ?? ""}
            onChange={(e) => setValues((v) => ({ ...v, [p]: e.target.value }))}
          />
        </label>
      ))}
      <label className="mt-2 block text-xs text-ink-3">
        Reason (goes in the audit row){tier2 ? "" : " — optional"}
        <input
          autoFocus={autoFocus && free.length === 0}
          className="mt-1 block w-full rounded border border-line bg-surface px-2 py-1 text-sm text-ink"
          value={reason}
          placeholder="why, in one line"
          onChange={(e) => setReason(e.target.value)}
        />
      </label>
      <div className="mt-3 flex gap-2">
        <Button type="submit" variant="primary" size="sm" disabled={!ready || run.isPending}>
          {run.isPending ? (tier2 ? "Requesting…" : "Running…") : tier2 ? "Request — needs approval" : "Run"}
        </Button>
        <Button type="button" size="sm" variant="ghost" onClick={onClose}>
          Cancel
        </Button>
      </div>
    </form>
  );
}

function FixedParam({ k, v }: { k: string; v: unknown }) {
  return (
    <>
      <dt className="text-ink-3">{k}</dt>
      <dd className="font-mono text-ink-2">{String(v)}</dd>
    </>
  );
}
