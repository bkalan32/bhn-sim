// Day 22 Step 2 — the incident page, "the heart of the product": the Day 9, 10, 12 and 17
// outputs laid out for a human. Header · context · hypothesis + KB · timeline + note box ·
// actions rail · AI drafts with a thumbs up/down that writes an eval row.
import { useEffect, useMemo, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useActions, useApprovals, useConfig, useEvals, useIncident, useKB } from "../lib/queries";
import { post, ApiError } from "../lib/api";
import { duration, num, severityTone, utcDateTime, utcTime } from "../lib/format";
import { exploreUrl, splunkUrl, dashboardUrl, SERVICE_DASHBOARD } from "../lib/links";
import { confidenceOf, isUnavailable, kbCited, splitDraft } from "../lib/drafts";
import { href } from "../lib/router";
import { getSession } from "../lib/session";
import type { Incident as Inc, KBEntry, TimelineEvent, UIConfig } from "../lib/types";
import { ApprovalCard } from "../components/approvals";
import { ActionButton } from "../components/actions";
import { useToast } from "../components/toast";
import { Markdown } from "../components/markdown";
import { Badge, Button, Card, CopyButton, ExtLink, Skeleton, Status, TierBadge, Unavailable, cx } from "../components/ui";

export function Incident({ id }: { id: string }) {
  const { data: inc, isLoading, error } = useIncident(id);
  const { data: cfg } = useConfig();
  if (isLoading) return <Skeleton className="h-64" />;
  if (error || !inc) return <Card title={id}><Unavailable what="incident" error={String(error ?? "not found")} /></Card>;
  return (
    <div className="flex flex-col gap-4">
      <Header inc={inc} />
      <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_380px]">
        <div className="flex min-w-0 flex-col gap-4">
          {cfg && <Context inc={inc} cfg={cfg} />}
          <Hypothesis inc={inc} />
          <Timeline inc={inc} />
          <Drafts inc={inc} />
        </div>
        <ActionsRail inc={inc} />
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- header --
function Header({ inc }: { inc: Inc }) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (inc.status !== "open") return;
    const t = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(t);
  }, [inc.status]);
  const dur = inc.duration_min != null ? inc.duration_min * 60 : (now / 1000 - inc.opened_at);
  const mttd = inc.first_alert_at ? inc.opened_at - inc.first_alert_at : null;
  return (
    <header className="rounded-lg border border-line bg-surface-2 p-4">
      <div className="flex flex-wrap items-center gap-3">
        <a href={href("incidents")} className="text-sm text-ink-3 hover:text-ink">← Incidents</a>
        <h1 className="font-mono text-xl font-semibold">{inc.id}</h1>
        <Status tone={inc.status === "open" ? "warning" : "good"} label={inc.status} />
        <Badge tone={severityTone(inc.severity)}>{inc.severity}</Badge>
        <Badge>{inc.service ?? "?"}</Badge>
      </div>
      <dl className="mt-3 grid grid-cols-2 gap-x-6 gap-y-2 text-sm sm:grid-cols-4">
        <Fact k="Opened" v={utcDateTime(inc.opened_at_iso)} />
        <Fact k={inc.status === "open" ? "Open for" : "Duration"} v={duration(dur)} />
        <Fact k="First alert" v={utcTime(inc.first_alert_at_iso)} />
        <Fact k="Alert → ticket (MTTD part)" v={mttd != null ? duration(mttd) : "not known"} />
      </dl>
      <p className="mt-2 text-xs text-ink-3">Alerts: {inc.alerts.join(", ")}</p>
    </header>
  );
}

function Fact({ k, v }: { k: string; v: string }) {
  return (
    <div>
      <dt className="text-xs text-ink-3">{k}</dt>
      <dd className="tabular font-mono text-ink">{v}</dd>
    </div>
  );
}

// --------------------------------------------------------------- context --
function Context({ inc, cfg }: { inc: Inc; cfg: UIConfig }) {
  const ctx = inc.context;
  const svc = inc.service ?? "";
  const from = ((inc.first_alert_at ?? inc.opened_at) - 30 * 60) * 1000;
  const to = inc.resolved_at ? (inc.resolved_at + 10 * 60) * 1000 : undefined;
  const meta = inc.context_meta ?? {};
  const errs = Object.entries(meta).filter(([, m]) => m && m.ok === false);
  return (
    <Card title="Context (Day 10 — collected when the ticket opened)" actions={ctx && <span className="text-xs text-ink-3">at {utcTime(ctx.collected_at)}</span>}>
      {!ctx ? (
        <p className="text-sm text-ink-3">No context attached yet — the collectors run in the background after the ticket opens.</p>
      ) : (
        <div className="grid gap-4 md:grid-cols-3">
          <div>
            <h3 className="mb-1 text-xs font-semibold text-ink-3">Metrics snapshot</h3>
            <ul className="space-y-1 text-sm">
              {Object.entries(ctx.metrics ?? {}).map(([k, v]) => {
                const q = cfg.metric_queries[svc]?.[k];
                return (
                  <li key={k} className="flex justify-between gap-2">
                    {q ? <ExtLink href={exploreUrl(cfg, q, from, to)} className="text-xs">{k}</ExtLink> : <span className="text-xs text-ink-2">{k}</span>}
                    <span className="tabular font-mono">{typeof v === "number" ? num(v, 2) : String(v ?? "—")}</span>
                  </li>
                );
              })}
            </ul>
          </div>
          <div>
            <h3 className="mb-1 text-xs font-semibold text-ink-3">
              Recent deploys{" "}
              {SERVICE_DASHBOARD[svc] && <ExtLink href={dashboardUrl(cfg, SERVICE_DASHBOARD[svc], from, to)} className="font-normal">annotations</ExtLink>}
            </h3>
            <ul className="space-y-1.5 text-xs">
              {(ctx.recent_deploys ?? []).map((d, i) => (
                <li key={i} className="text-ink-2">
                  {d.note || d.error ? (
                    <span className="text-ink-3">{d.note ?? d.error}</span>
                  ) : (
                    <>
                      <Badge tone={d.kind === "rollback" ? "warning" : "info"}>{d.kind}</Badge>{" "}
                      <span className="tabular font-mono">{utcTime(d.at_iso)}</span>
                      {d.minutes_before_first_alert != null && (
                        <span className="text-ink-3"> · {d.minutes_before_first_alert >= 0 ? `${d.minutes_before_first_alert} min before` : `${-d.minutes_before_first_alert} min after`} the first alert</span>
                      )}
                      <span className="block truncate text-ink-3" title={d.text}>{d.text}</span>
                    </>
                  )}
                </li>
              ))}
            </ul>
          </div>
          <div>
            <h3 className="mb-1 text-xs font-semibold text-ink-3">
              Top log reasons{" "}
              <ExtLink className="font-normal" href={splunkUrl(cfg, cfg.log_reasons_spl.replace("{service}", svc), from / 1000, to ? to / 1000 : undefined)}>Splunk</ExtLink>
            </h3>
            <ReasonBars rows={ctx.top_error_reasons ?? []} />
          </div>
        </div>
      )}
      {errs.length > 0 && (
        <p className="mt-3 text-xs text-ink-3">
          ⚠ collector errors: {errs.map(([k, m]) => `${k}: ${m.error ?? "failed"}`).join("; ")} — the hypothesis should say its confidence is lower.
        </p>
      )}
    </Card>
  );
}

function ReasonBars({ rows }: { rows: { reason?: string; count?: number; note?: string; error?: string }[] }) {
  const real = rows.filter((r) => r.reason !== undefined && r.count !== undefined);
  if (!real.length) return <p className="text-xs text-ink-3">{rows[0]?.note ?? rows[0]?.error ?? "none"}</p>;
  const max = Math.max(...real.map((r) => r.count ?? 0), 1);
  return (
    <ul className="space-y-1.5">
      {real.map((r) => (
        <li key={r.reason} className="text-xs">
          <div className="flex justify-between gap-2">
            <span className="truncate font-mono text-ink-2">{r.reason || "(none)"}</span>
            <span className="tabular font-mono">{r.count}</span>
          </div>
          <div className="mt-0.5 h-1.5 rounded bg-surface-3">
            <div className="h-1.5 rounded bg-info" style={{ width: `${Math.max(4, ((r.count ?? 0) / max) * 100)}%` }} />
          </div>
        </li>
      ))}
    </ul>
  );
}

// ------------------------------------------------------------ hypothesis --
function Hypothesis({ inc }: { inc: Inc }) {
  const text = inc.ai_hypothesis;
  const conf = confidenceOf(text);
  const cited = kbCited(text);
  const offered = (inc.ai_meta?.hypothesis?.kb_matches ?? []).map((m) => m.id);
  return (
    <Card
      title="Hypothesis (Day 10 · Day 17 — diagnosis only)"
      actions={
        <>
          {conf && <Badge tone={conf === "high" ? "good" : conf === "medium" ? "warning" : "critical"}>confidence {conf}</Badge>}
          {inc.ai_meta?.hypothesis?.model && <span className="text-[11px] text-ink-3">{inc.ai_meta.hypothesis.model}</span>}
          {text && !isUnavailable(text) && <CopyButton text={text} />}
        </>
      }
    >
      {!text ? (
        <p className="text-sm text-ink-3">Drafting — the bot writes it after the context arrives (usually under a minute).</p>
      ) : (
        <>
          <div className="mb-3 flex flex-wrap items-center gap-2 text-xs">
            <span className="text-ink-3">KB cited:</span>
            {cited.length === 0 && <span className="text-ink-3">none</span>}
            {cited.map((k) => (
              <a key={k} href={href("kb", k)} className={cx("rounded-full border px-2 py-0.5 font-mono hover:bg-surface-3", offered.includes(k) ? "border-info text-ink" : "border-critical text-ink")}
                title={offered.includes(k) ? "offered to the model and cited" : "cited but NOT offered to the model — check it (ai-eval Eval 8)"}>
                {k}{!offered.includes(k) && " ⚠"}
              </a>
            ))}
            {offered.filter((k) => !cited.includes(k)).length > 0 && (
              <>
                <span className="ml-2 text-ink-3">offered, not cited:</span>
                {offered.filter((k) => !cited.includes(k)).map((k) => (
                  <a key={k} href={href("kb", k)} className="rounded-full border border-line px-2 py-0.5 font-mono text-ink-3 hover:bg-surface-3">{k}</a>
                ))}
              </>
            )}
          </div>
          <Markdown text={text} />
          <Thumbs inc={inc} draft="hypothesis" />
        </>
      )}
    </Card>
  );
}

// -------------------------------------------------------------- timeline --
function Timeline({ inc }: { inc: Inc }) {
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const toast = useToast();
  const qc = useQueryClient();
  const events = useMemo(() => [...inc.timeline].sort((a, b) => a.ts - b.ts), [inc.timeline]);

  const submit = async () => {
    setBusy(true);
    try {
      const r = await post<{ status: string; detail?: string }>(`/api/incidents/${encodeURIComponent(inc.id)}/notes`, { text: text.trim() });
      if (r.status === "executed") {
        setText("");
        toast({ tone: "good", title: "Note added", detail: `as ${getSession()?.operator} · audited` });
      } else toast({ tone: "critical", title: `Note ${r.status}`, detail: r.detail });
      qc.invalidateQueries({ queryKey: ["incident", inc.id] });
    } catch (e) {
      toast({ tone: "critical", title: "Note refused", detail: e instanceof ApiError ? `${e.status}: ${e.message}` : String(e) });
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card title={`Timeline · ${events.length} events`}>
      <ol className="relative space-y-3 border-l border-line pl-4">
        {events.map((e, i) => (
          <TimelineRow key={`${e.ts}-${i}`} e={e} />
        ))}
      </ol>
      <div className="mt-4 border-t border-line pt-3">
        <label htmlFor="note" className="text-xs text-ink-3">
          Add a note — tier 1, lands in the audit log as <span className="text-ink-2">{getSession()?.operator}</span>
        </label>
        <textarea
          id="note"
          rows={3}
          value={text}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey) && text.trim() && !busy) void submit();
          }}
          placeholder="What you saw, what you did, what you ruled out…"
          className="mt-1 block w-full rounded-md border border-line bg-surface px-3 py-2 text-sm text-ink placeholder:text-ink-3"
        />
        <div className="mt-2 flex items-center justify-between">
          <span className="text-[11px] text-ink-3">Ctrl+Enter to post</span>
          <Button variant="primary" size="sm" disabled={!text.trim() || busy} onClick={() => void submit()}>
            {busy ? "Posting…" : "Post note"}
          </Button>
        </div>
      </div>
    </Card>
  );
}

function TimelineRow({ e }: { e: TimelineEvent }) {
  let dot = "bg-ink-3";
  let body: React.ReactNode;
  switch (e.event) {
    case "alerts_firing":
      dot = "bg-critical";
      body = <>Firing: {(e.alerts ?? []).map((a) => a.name).join(", ")}{e.alerts?.[0]?.summary && <span className="block text-xs text-ink-3">{e.alerts[0].summary}</span>}</>;
      break;
    case "alerts_resolved":
      dot = "bg-good";
      body = <>Resolved: {(e.alerts ?? []).map((a) => a.name).join(", ")}</>;
      break;
    case "incident_resolved":
      dot = "bg-good";
      body = <span className="font-semibold">Incident resolved after {e.duration_min} min</span>;
      break;
    case "context_attached":
      body = <>Context attached ({Object.entries(e.collectors ?? {}).map(([k, v]) => `${k} ${v}`).join(", ")}{e.latency_ms != null ? `, ${e.latency_ms} ms` : ""})</>;
      break;
    case "ai_draft_attached":
      dot = "bg-info";
      body = <>AI {e.draft} draft {e.ok ? "attached" : "failed"}{e.model ? ` · ${e.model}` : ""}{e.latency_ms != null ? ` · ${(Number(e.latency_ms) / 1000).toFixed(1)} s` : ""}</>;
      break;
    case "note":
      dot = e.author === "remediator" ? "bg-warning" : "bg-info";
      body = (
        <>
          <span className="text-xs font-semibold text-ink-2">{e.author ?? "responder"}</span>
          <span className="block whitespace-pre-wrap text-ink">{e.text}</span>
        </>
      );
      break;
    default: {
      const { ts: _ts, ts_iso: _iso, event, ...rest } = e;
      void _ts; void _iso;
      body = <>{event} <span className="font-mono text-xs text-ink-3">{JSON.stringify(rest).slice(0, 160)}</span></>;
    }
  }
  return (
    <li className="relative text-sm">
      <span aria-hidden className={cx("absolute -left-[21px] top-1.5 h-2.5 w-2.5 rounded-full ring-2 ring-surface-2", dot)} />
      <time className="tabular mr-2 font-mono text-xs text-ink-3">{utcTime(e.ts_iso)}</time>
      <span className="text-ink-2">{body}</span>
    </li>
  );
}

// ---------------------------------------------------------------- drafts --
function Drafts({ inc }: { inc: Inc }) {
  return (
    <Card title="AI drafts (Day 9 · Day 17) — copy, then grade">
      <DraftBlock inc={inc} kind="open" text={inc.ai_open_draft} waiting="written when the ticket opens" />
      <div className="my-4 border-t border-line" />
      <DraftBlock inc={inc} kind="resolved" text={inc.ai_resolution_draft}
        waiting={inc.status === "open" ? "written when the incident resolves" : "drafting — refreshes on its own"} />
    </Card>
  );
}

function DraftBlock({ inc, kind, text, waiting }: { inc: Inc; kind: "open" | "resolved"; text?: string; waiting: string }) {
  const parts = splitDraft(text);
  const title = kind === "open" ? "Opening: internal summary · stakeholder update" : "Resolution: note · stakeholder close-out · review skeleton";
  return (
    <div>
      <div className="mb-2 flex items-center justify-between gap-2">
        <h3 className="text-sm font-semibold text-ink-2">{title}</h3>
        {inc.ai_meta?.[kind]?.model && <span className="text-[11px] text-ink-3">{inc.ai_meta[kind].model}</span>}
      </div>
      {!text ? (
        <p className="text-sm text-ink-3">Not yet — {waiting}.</p>
      ) : isUnavailable(text) ? (
        <Unavailable what="draft" error={text} />
      ) : (
        <>
          <div className="space-y-3">
            {parts.map((p, i) => (
              <div key={i} className="rounded-md border border-line bg-surface p-3">
                <div className="mb-1 flex items-center justify-between gap-2">
                  <span className="text-xs font-semibold uppercase tracking-wider text-ink-3">{p.heading || "Draft"}</span>
                  <CopyButton text={p.body} />
                </div>
                <Markdown text={p.body} />
              </div>
            ))}
          </div>
          <Thumbs inc={inc} draft={kind} />
        </>
      )}
    </div>
  );
}

function Thumbs({ inc, draft }: { inc: Inc; draft: "open" | "hypothesis" | "resolved" }) {
  const { data: evals } = useEvals(inc.id);
  const toast = useToast();
  const qc = useQueryClient();
  const [comment, setComment] = useState("");
  const [busy, setBusy] = useState(false);
  const mine = evals?.filter((e) => e.draft === draft) ?? [];
  const me = getSession()?.operator;
  const my = mine.find((e) => e.operator === me);
  const up = mine.filter((e) => e.verdict === "up").length;
  const down = mine.length - up;

  const rate = async (verdict: "up" | "down") => {
    setBusy(true);
    try {
      await post("/api/eval", { incident: inc.id, draft, verdict, comment, model: inc.ai_meta?.[draft]?.model ?? null });
      toast({ tone: "good", title: `Graded the ${draft} draft ${verdict === "up" ? "👍" : "👎"}`, detail: "eval row written · audited as rate_draft" });
      setComment("");
      qc.invalidateQueries({ queryKey: ["evals", inc.id] });
    } catch (e) {
      toast({ tone: "critical", title: "Grade refused", detail: e instanceof ApiError ? `${e.status}: ${e.message}` : String(e) });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="mt-3 flex flex-wrap items-center gap-2 text-xs">
      <span className="text-ink-3">Was this draft right?</span>
      <Button size="sm" variant={my?.verdict === "up" ? "primary" : "secondary"} disabled={busy} onClick={() => void rate("up")} aria-label="Thumbs up">
        👍 {up || ""}
      </Button>
      <Button size="sm" variant={my?.verdict === "down" ? "danger" : "secondary"} disabled={busy} onClick={() => void rate("down")} aria-label="Thumbs down">
        👎 {down || ""}
      </Button>
      <input
        value={comment}
        onChange={(e) => setComment(e.target.value)}
        placeholder="optional: what it got wrong"
        className="min-w-48 flex-1 rounded border border-line bg-surface px-2 py-1 text-xs text-ink placeholder:text-ink-3"
      />
    </div>
  );
}

// ---------------------------------------------------------- actions rail --
function ActionsRail({ inc }: { inc: Inc }) {
  const { data: approvals } = useApprovals();
  const { data: catalog } = useActions();
  const { data: kb } = useKB();
  const svc = inc.service ?? "";
  const mine = (approvals ?? []).filter((a) => a.incident === inc.id || (a.params?.service && a.params.service === svc));
  const cited = kbCited(inc.ai_hypothesis);
  const offered = (inc.ai_meta?.hypothesis?.kb_matches ?? []).map((m) => m.id);
  const kbIds = cited.length ? cited : offered.slice(0, 1);
  const entries = kbIds.map((k) => kb?.find((e) => e.id === k)).filter(Boolean) as KBEntry[];
  const tier3 = entries.find((e) => String(e.tier) === "3");
  const byId = (id: string) => catalog?.find((a) => a.id === id);

  const tier1 = [svc === "settlement" ? "rerun_settlement" : null, "run_drift_check", "generate_report"].filter(Boolean) as string[];
  const tier2: { id: string; fixed: Record<string, unknown>; label?: string }[] = [];
  if (byId("rollback")?.services?.includes(svc)) tier2.push({ id: "rollback", fixed: { service: svc }, label: `Roll back ${svc}` });
  if (byId("scale")?.services?.includes(svc)) tier2.push({ id: "scale", fixed: { service: svc }, label: `Scale ${svc}` });
  if (byId("deploy")?.services?.includes(svc)) tier2.push({ id: "deploy", fixed: { service: svc, skip_verify: "false" }, label: `Deploy ${svc}` });
  if (byId("silence_alert")) tier2.push({ id: "silence_alert", fixed: { service: svc, alertname: inc.alerts[0] ?? "" }, label: `Silence ${inc.alerts[0] ?? "alert"}` });

  return (
    <aside className="flex flex-col gap-4" aria-label="Actions">
      <Card title={`Waiting for approval${mine.length ? ` · ${mine.length}` : ""}`} tone={mine.length ? "warning" : undefined}>
        {mine.length === 0 ? (
          <p className="text-sm text-ink-3">No proposals for {svc || "this service"}.</p>
        ) : (
          <div className="flex flex-col gap-2">{mine.map((a) => <ApprovalCard key={a.token} a={a} compact />)}</div>
        )}
      </Card>

      {tier3 ? (
        <section className="rounded-lg border border-line bg-surface-3 p-4">
          <h2 className="text-sm font-semibold text-ink">No safe automated action: escalate</h2>
          <p className="mt-1 text-xs text-ink-3">
            Tier 3 per <a className="text-info hover:underline" href={href("kb", tier3.id ?? "")}>{tier3.id}</a> — {tier3.title}. There is no button for this on purpose.
          </p>
          {tier3.fix && <p className="mt-2 text-sm text-ink-2">{tier3.fix}</p>}
        </section>
      ) : (
        entries.map((e) => (
          <section key={e.id} className="rounded-lg border border-line bg-surface-2 p-4 text-sm">
            <div className="flex items-center gap-2">
              <a className="font-mono text-info hover:underline" href={href("kb", e.id ?? "")}>{e.id}</a>
              <TierBadge tier={e.tier} />
            </div>
            <p className="mt-1 text-xs text-ink-3">{e.title}</p>
            {e.fix && <p className="mt-2 text-ink-2">{e.fix}</p>}
          </section>
        ))
      )}

      <Card title="Tier 1 — one click, audited">
        <div className="flex flex-wrap gap-2">
          {tier1.map((id) => byId(id) && <ActionButton key={id} action={byId(id)!} />)}
        </div>
      </Card>

      <Card title="Tier 2 — request, then a human approves">
        {tier2.length === 0 ? (
          <p className="text-sm text-ink-3">No tier-2 actions apply to {svc || "this service"}.</p>
        ) : (
          <div className="flex flex-col items-start gap-2">
            {tier2.map((t) => byId(t.id) && <ActionButton key={t.id} action={byId(t.id)!} fixed={t.fixed} label={t.label} />)}
          </div>
        )}
      </Card>
    </aside>
  );
}
