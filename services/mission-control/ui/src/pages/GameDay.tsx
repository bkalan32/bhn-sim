// Day 24 Step 1 — the Game Day console: the screen where you are allowed to break things.
// Every knob is a tier-2 request (set_fault) with the same confirmation card as any fix; a scenario
// is ONE tier-2 approval for a schedule that runs server-side, sealed until Retro; Reset all is the
// tier-1 click every game day ends with. While a run is sealed this page does not show the knobs'
// values — the console must not give the game away.
import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { api, post, ApiError } from "../lib/api";
import { useActions, useGameDay } from "../lib/queries";
import { utcDateTime, utcTime } from "../lib/format";
import type { Action, GameDayState, KnobTarget, Run } from "../lib/types";
import { ActionButton, ConfirmCard } from "../components/actions";
import { useToast } from "../components/toast";
import { Badge, Button, Card, CopyButton, Skeleton, Status, TierBadge, Unavailable, cx } from "../components/ui";

const TARGET_LABEL: Record<string, string> = {
  activation: "activation (Deployment)",
  egift: "egift (Deployment)",
  settlement: "settlement (CronJob)",
  "loadgen-activation": "traffic → activation",
  "loadgen-egift": "traffic → egift",
};

export function GameDay() {
  const { data, isLoading, error } = useGameDay();
  const { data: catalog } = useActions();
  const byId = (id: string) => catalog?.find((a) => a.id === id);
  const reset = byId("reset_faults");

  if (isLoading) return <Skeleton className="h-96" />;
  if (error || !data) return <Unavailable what="game day" error={String(error)} />;
  const sealed = "sealed" in data.knobs;

  return (
    <div className="flex flex-col gap-4">
      {data.sealed_run && (
        <div className="rounded-lg border border-warning/70 bg-surface-2 px-4 py-3 text-sm">
          <span className="font-semibold text-ink">{data.sealed_run} is sealed.</span>{" "}
          <span className="text-ink-2">
            Its steps run server-side and stay hidden until Retro. Respond from the other screens — and write down every
            time you leave the browser.
          </span>
        </div>
      )}
      <div className="grid gap-4 xl:grid-cols-[minmax(0,1.3fr)_minmax(0,1fr)]">
        <Card
          title="Fault knobs — live from the cluster"
          actions={reset && <ActionButton action={reset} label="Reset all" />}
        >
          {sealed ? (
            <p className="text-sm text-ink-3">
              Hidden while <span className="font-mono">{(data.knobs as { run: string }).run}</span> is sealed. Retro reveals the
              plan; Reset all puts every knob back and shows them again.
            </p>
          ) : (
            <Knobs knobs={data.knobs as Record<string, KnobTarget>} setFault={byId("set_fault")} />
          )}
          <p className="mt-3 text-[11px] text-ink-3">
            Each change is a tier-2 request — it waits in the banner for a second click, like any fix. Reset all is tier 1:
            putting things back is always safe.
          </p>
        </Card>
        <Scenarios data={data} runScenario={byId("run_scenario")} />
      </div>
      <Runs runs={data.runs} annotations={data.annotations} />
    </div>
  );
}

function Knobs({ knobs, setFault }: { knobs: Record<string, KnobTarget>; setFault?: Action }) {
  const [editing, setEditing] = useState<string | null>(null);
  return (
    <table className="w-full text-sm">
      <thead>
        <tr className="text-left text-xs text-ink-3">
          <th className="pb-2 font-normal">Target</th>
          <th className="pb-2 font-normal">Knob</th>
          <th className="pb-2 font-normal">Now</th>
          <th className="pb-2 font-normal">Baseline</th>
          <th className="pb-2" />
        </tr>
      </thead>
      <tbody>
        {Object.entries(knobs).flatMap(([target, t]) =>
          t.error
            ? [
                <tr key={target} className="border-t border-line/60">
                  <td className="py-2 text-ink-2">{TARGET_LABEL[target] ?? target}</td>
                  <td colSpan={4} className="py-2 text-xs text-critical">cannot read: {t.error}</td>
                </tr>,
              ]
            : Object.entries(t.knobs).map(([knob, k], i) => {
                const key = `${target}/${knob}`;
                return (
                  <tr key={key} className="border-t border-line/60 align-top">
                    <td className="py-2 text-ink-2">{i === 0 ? TARGET_LABEL[target] ?? target : ""}</td>
                    <td className="py-2 font-mono text-xs">{knob}</td>
                    <td className="py-2">
                      <span className={cx("font-mono text-xs", k.at_baseline ? "text-ink-2" : "font-semibold text-warning")}>{k.value}</span>
                      {!k.at_baseline && <Badge tone="warning" className="ml-2">off baseline</Badge>}
                    </td>
                    <td className="py-2 font-mono text-xs text-ink-3">{k.baseline}</td>
                    <td className="py-2 text-right">
                      {setFault && (
                        <Button size="sm" variant={editing === key ? "ghost" : "secondary"} onClick={() => setEditing(editing === key ? null : key)}>
                          Change…
                        </Button>
                      )}
                      {editing === key && setFault && (
                        <div className="text-left">
                          <ConfirmCard action={setFault} fixed={{ target, knob }} onClose={() => setEditing(null)} />
                        </div>
                      )}
                    </td>
                  </tr>
                );
              }),
        )}
      </tbody>
    </table>
  );
}

function Scenarios({ data, runScenario }: { data: GameDayState; runScenario?: Action }) {
  const [open, setOpen] = useState<string | null>(null);
  return (
    <Card title={`Scenarios · ${data.scenarios.length}`}>
      {data.scenarios.length === 0 && (
        <p className="text-sm text-ink-3">None loaded — ./scripts/240-gameday.sh ships gameday/*.yaml as the ConfigMap this pod mounts.</p>
      )}
      <ul className="space-y-3">
        {data.scenarios.map((s) => (
          <li key={s.id} className="rounded-md border border-line bg-surface p-3">
            <div className="flex items-start justify-between gap-2">
              <div>
                <p className="font-semibold text-ink">{s.title}</p>
                <p className="font-mono text-[11px] text-ink-3">{s.file}</p>
              </div>
              {runScenario && (
                <Button size="sm" variant="primary" disabled={!!data.sealed_run} onClick={() => setOpen(open === s.id ? null : s.id)}
                  title={data.sealed_run ? "a run is sealed — Retro or Reset all first" : "one approval runs the whole schedule"}>
                  Run sealed…
                </Button>
              )}
            </div>
            {s.summary && <p className="mt-2 text-sm text-ink-2">{s.summary}</p>}
            {open === s.id && runScenario && (
              <ConfirmCard action={runScenario} fixed={{ scenario: s.id }} reasonDefault={`game day: ${s.id}`} onClose={() => setOpen(null)} />
            )}
          </li>
        ))}
      </ul>
      {Object.entries(data.scenario_errors).map(([f, e]) => (
        <p key={f} className="mt-2 text-xs text-critical">
          <span className="font-mono">{f}</span> is invalid: {e}
        </p>
      ))}
      <p className="mt-3 text-[11px] text-ink-3">
        The steps are never shown before a run. The approval card names the scenario, not what it does.
      </p>
    </Card>
  );
}

function Runs({ runs, annotations }: { runs: Run[]; annotations: boolean }) {
  const [skeleton, setSkeleton] = useState<{ run: string; md: string } | null>(null);
  const qc = useQueryClient();
  const toast = useToast();
  const act = async (run: string, what: "retro" | "abort") => {
    try {
      await post(`/api/gameday/runs/${run}/${what}`);
      qc.invalidateQueries({ queryKey: ["gameday"] });
      toast({ tone: what === "retro" ? "good" : "warning", title: what === "retro" ? `${run} revealed` : `${run} aborted` });
    } catch (e) {
      toast({ tone: "critical", title: `${what} refused`, detail: e instanceof ApiError ? e.message : String(e) });
    }
  };
  const showSkeleton = async (run: string) => {
    try {
      setSkeleton({ run, md: await api<string>(`/api/gameday/runs/${run}/skeleton`) });
    } catch (e) {
      toast({ tone: "critical", title: "No skeleton", detail: e instanceof ApiError ? e.message : String(e) });
    }
  };
  return (
    <Card title={`Runs · ${runs.length}`} actions={!annotations && <span className="text-[11px] text-ink-3">no Grafana markers (241-mc-grafana-writer.sh)</span>}>
      {runs.length === 0 && <p className="text-sm text-ink-3">No game day run from the console yet.</p>}
      <ul className="divide-y divide-line/60">
        {runs.map((r) => (
          <li key={r.id} className="py-3">
            <div className="flex flex-wrap items-center gap-2 text-sm">
              <span className="font-mono text-ink">{r.id}</span>
              <Badge>{r.scenario}</Badge>
              <Status tone={r.sealed ? "warning" : r.status === "aborted" ? "neutral" : "good"} label={r.sealed ? "sealed" : r.status} />
              <span className="text-xs text-ink-3">
                approved by {r.operator} · started {utcDateTime(r.started_at_iso)}
                {r.reset_at_iso ? ` · reset ${utcTime(r.reset_at_iso)}` : ""}
                {r.revealed_at_iso ? ` · retro ${utcTime(r.revealed_at_iso)}` : ""}
              </span>
              <span className="ml-auto flex gap-2">
                {r.sealed && !r.reset_at_iso && r.status !== "aborted" && (
                  <Button size="sm" variant="ghost" onClick={() => void act(r.id, "abort")} title="skip the remaining steps (the faults already injected stay)">
                    Abort
                  </Button>
                )}
                {r.sealed && (
                  <Button size="sm" variant="primary" onClick={() => void act(r.id, "retro")} title="reveal the plan — ends the run if steps are still pending">
                    Retro
                  </Button>
                )}
                {!r.sealed && (
                  <Button size="sm" onClick={() => void showSkeleton(r.id)}>
                    Run skeleton
                  </Button>
                )}
              </span>
            </div>
            {r.steps && (
              <table className="mt-2 w-full text-xs">
                <tbody>
                  {r.steps.map((s) => (
                    <tr key={s.n} className="border-t border-line/40 align-top">
                      <td className="py-1 pr-2 text-ink-3">#{s.n}</td>
                      <td className="py-1 pr-2 font-mono text-ink-3">{s.offset_s != null ? `+${s.offset_s}s` : `+${s.at_seconds}s planned`}</td>
                      <td className="py-1 pr-2 font-mono text-ink">
                        {s.params.target} {s.params.knob}={s.params.value}
                      </td>
                      <td className="py-1 pr-2">
                        <Status tone={s.state === "fired" ? "good" : s.state === "failed" ? "critical" : "neutral"} label={s.state} />
                      </td>
                      <td className="py-1 text-ink-2">{s.note}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </li>
        ))}
      </ul>
      {skeleton && (
        <div className="mt-3 rounded-md border border-line bg-surface p-3">
          <div className="mb-2 flex items-center justify-between gap-2">
            <span className="text-xs text-ink-3">
              gameday/{skeleton.run}.md — <span className="font-mono">./scripts/245-gameday-run.sh {skeleton.run}</span> saves it into the repo
            </span>
            <span className="flex gap-2">
              <CopyButton text={skeleton.md} />
              <Button size="sm" variant="ghost" onClick={() => setSkeleton(null)}>Close</Button>
            </span>
          </div>
          <pre className="max-h-[60vh] overflow-auto whitespace-pre-wrap font-mono text-xs text-ink-2">{skeleton.md}</pre>
        </div>
      )}
      <p className="mt-3 text-[11px] text-ink-3">
        <TierBadge tier={1} /> Retro and Abort are record-keeping, audited under your name. Retro is also when the Grafana
        markers get their real text.
      </p>
    </Card>
  );
}
