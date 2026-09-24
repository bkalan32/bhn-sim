// Day 24 Step 3 — the daily report archive. Generate now (tier 1: triggers the Jenkins job; the feed
// says when the bot receives the result), a thumbs + note per report like a copilot answer, and three
// days side by side — Day 18's "boring days must read boring" test as a habit with a UI.
import { useEffect, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { post, ApiError } from "../lib/api";
import { useActions, useEvalRows, useReport, useReports } from "../lib/queries";
import { utcDateTime } from "../lib/format";
import { ActionButton } from "../components/actions";
import { Markdown } from "../components/markdown";
import { useToast } from "../components/toast";
import { Badge, Button, Card, Skeleton, Unavailable, cx } from "../components/ui";

export function Reports() {
  const { data, isLoading, error } = useReports();
  const { data: catalog } = useActions();
  const gen = catalog?.find((a) => a.id === "generate_report");
  const [picked, setPicked] = useState<string[]>([]);
  useEffect(() => {
    if (data && picked.length === 0) setPicked(data.slice(0, 3).map((r) => r.day).reverse());
  }, [data]); // eslint-disable-line react-hooks/exhaustive-deps
  const toggle = (day: string) =>
    setPicked((p) => (p.includes(day) ? p.filter((d) => d !== day) : [...p, day].slice(-3)).sort());

  return (
    <div className="flex flex-col gap-4">
      <Card
        title={`Daily reports${data ? ` · ${data.length}` : ""}`}
        actions={gen && <ActionButton action={gen} label="Generate now" />}
      >
        {isLoading && <Skeleton className="h-24" />}
        {error && <Unavailable what="reports" error={String(error)} />}
        <p className="mb-2 text-xs text-ink-3">
          Pick up to three to read side by side. Generate now runs the Jenkins job (~1–3 min with the drift plan); the feed
          says when the bot has the result.
        </p>
        <div className="flex flex-wrap gap-2">
          {(data ?? []).map((r) => (
            <button key={r.day} onClick={() => toggle(r.day)}
              className={cx("rounded-md border px-2 py-1 text-left text-xs", picked.includes(r.day) ? "border-info bg-surface-3 text-ink" : "border-line text-ink-2 hover:bg-surface-3")}>
              <span className="font-mono">{r.day}</span>
              <span className="ml-2 text-ink-3">{r.words} words</span>
            </button>
          ))}
        </div>
      </Card>
      <div className={cx("grid gap-4", picked.length >= 3 ? "xl:grid-cols-3" : picked.length === 2 ? "lg:grid-cols-2" : "")}>
        {picked.map((d) => (
          <ReportCard key={d} day={d} />
        ))}
      </div>
    </div>
  );
}

function ReportCard({ day }: { day: string }) {
  const { data, isLoading, error } = useReport(day);
  const { data: evals } = useEvalRows();
  const mine = (evals ?? []).filter((e) => e.incident === `report:${day}`);
  return (
    <Card title={<span className="font-mono">{day}</span>}>
      {isLoading && <Skeleton className="h-64" />}
      {error && <Unavailable what={`report ${day}`} error={String(error)} />}
      {data && (
        <>
          <p className="mb-2 text-[11px] text-ink-3">
            {data.words} words · {data.model ?? "model ?"} · stored {utcDateTime(data.stored_at_iso)}
          </p>
          <Markdown text={data.text} />
          <div className="mt-3 border-t border-line pt-2">
            {mine.map((e) => (
              <p key={e.id} className="text-xs text-ink-3">
                <Badge tone={e.verdict === "up" ? "good" : "critical"}>{e.verdict === "up" ? "👍" : "👎"}</Badge> {e.operator}
                {e.comment ? ` — ${e.comment}` : ""}
              </p>
            ))}
            <Grade day={day} model={data.model} />
          </div>
        </>
      )}
    </Card>
  );
}

function Grade({ day, model }: { day: string; model: string | null }) {
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const qc = useQueryClient();
  const toast = useToast();
  const send = async (verdict: "up" | "down") => {
    setBusy(true);
    try {
      await post("/api/eval", { report: day, verdict, comment: note, model });
      setNote("");
      qc.invalidateQueries({ queryKey: ["evals", "all"] });
      toast({ tone: "good", title: `Report ${day} graded ${verdict === "up" ? "👍" : "👎"}` });
    } catch (e) {
      toast({ tone: "critical", title: "Grade refused", detail: e instanceof ApiError ? e.message : String(e) });
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="mt-2 flex flex-wrap items-center gap-2 text-xs">
      <Button size="sm" disabled={busy} onClick={() => void send("up")} aria-label="Good report">👍</Button>
      <Button size="sm" disabled={busy} onClick={() => void send("down")} aria-label="Bad report">👎</Button>
      <input value={note} onChange={(e) => setNote(e.target.value)} placeholder="one line: does a boring day read boring?"
        className="min-w-40 flex-1 rounded border border-line bg-surface px-2 py-1 text-xs text-ink placeholder:text-ink-3" />
    </div>
  );
}
