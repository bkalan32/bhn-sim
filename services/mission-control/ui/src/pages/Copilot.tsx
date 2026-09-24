// Day 23 Step 2 — the Copilot screen: the conversation on the left, the tool trail on the right.
// Every tool call is a card with the exact query and a collapsed result: "watching which queries the
// model chooses is how you learn to trust it" (Day 11), as a permanent part of the screen. An answer
// with no trail is visibly an answer with no evidence. Every answer can be graded in one click.
import { useEffect, useMemo, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { streamChat } from "../lib/chat";
import { post, ApiError } from "../lib/api";
import { useConfig } from "../lib/queries";
import { href } from "../lib/router";
import type { TrailItem } from "../lib/types";
import { Markdown } from "../components/markdown";
import { useToast } from "../components/toast";
import { Badge, Button, Card, cx } from "../components/ui";
import { takeCopilotDraft } from "./copilotDraft";

// docs/copilot-questions/warmup.txt — the Day 11 warm-up; Day 23's bar is that it passes from here.
const WARMUP = [
  "What is the overall platform health right now?",
  "What is the activation error rate and p95 latency over the last 5 minutes?",
  "Any open incidents?",
  "When did settlement last run successfully and how many records did it process?",
  "Which store had the most activation errors in the last 30 minutes?",
];

type Tool = TrailItem & { running?: boolean };
type Msg =
  | { role: "user"; text: string }
  | { role: "assistant"; text: string; thinking: string; tools: Tool[]; notices: string[]; done?: Done; error?: string; streaming: boolean };
type Done = { turn_id: number; model: string; tokens_in: number; tokens_out: number; cache_read: number; cost_usd: number | null; ms: number; tool_calls: number; note: string | null };
type Conv = { id: string | null; incident: string | null; msgs: Msg[]; updated: number };

// One conversation per incident, one for the page — kept while the tab lives, 30 minutes like the server.
const store = new Map<string, Conv>();
const keyOf = (incident?: string) => incident ?? "_page";

export function Copilot({ incident }: { incident?: string }) {
  const key = keyOf(incident);
  const fresh = (): Conv => ({ id: null, incident: incident ?? null, msgs: [], updated: Date.now() });
  const [conv, setConv] = useState<Conv>(() => {
    const c = store.get(key);
    return c && Date.now() - c.updated < 30 * 60_000 ? c : fresh();
  });
  const [input, setInput] = useState(() =>
    takeCopilotDraft() ??
    (incident && !store.get(key)?.msgs.length ? `Investigate ${incident}: what happened, what is the likely cause, and what should a human check next?` : ""),
  );
  const [busy, setBusy] = useState(false);
  const { data: cfg } = useConfig();
  const qc = useQueryClient();
  const bottom = useRef<HTMLDivElement>(null);

  useEffect(() => {
    store.set(key, conv);
  }, [key, conv]);
  useEffect(() => bottom.current?.scrollIntoView({ block: "end" }), [conv.msgs.length, busy]);

  const update = (fn: (m: Extract<Msg, { role: "assistant" }>) => void) =>
    setConv((c) => {
      const msgs = [...c.msgs];
      const last = { ...(msgs[msgs.length - 1] as Extract<Msg, { role: "assistant" }>) };
      last.tools = [...last.tools];
      last.notices = [...last.notices];
      fn(last);
      msgs[msgs.length - 1] = last;
      return { ...c, msgs, updated: Date.now() };
    });

  const ask = async (text: string) => {
    const q = text.trim();
    if (!q || busy) return;
    setInput("");
    setBusy(true);
    setConv((c) => ({
      ...c,
      updated: Date.now(),
      msgs: [...c.msgs, { role: "user", text: q }, { role: "assistant", text: "", thinking: "", tools: [], notices: [], streaming: true }],
    }));
    try {
      await streamChat({ message: q, conversation_id: conv.id, incident: conv.incident }, (e) => {
        switch (e.event) {
          case "conversation":
            setConv((c) => ({ ...c, id: e.data.conversation_id }));
            break;
          case "thinking":
            update((m) => { m.thinking += e.data.text; });
            break;
          case "text":
            update((m) => { m.text += e.data.text; });
            break;
          case "tool_start":
            update((m) => {
              if (m.thinking && !m.thinking.endsWith(" · ")) m.thinking += " · "; // one round's thinking ends at its tool call
              m.tools.push({ ...e.data, summary: "running…", ms: 0, error: false, running: true });
            });
            break;
          case "tool_call":
            update((m) => {
              const i = m.tools.findIndex((t) => t.id === e.data.id);
              if (i >= 0) m.tools[i] = e.data;
              else m.tools.push(e.data);
              if (e.data.name === "propose_action") qc.invalidateQueries({ queryKey: ["approvals"] });
            });
            break;
          case "fallback":
            update((m) => { m.notices.push(`answered by ${e.data.to} (server-side fallback from ${e.data.from})`); });
            break;
          case "notice":
            update((m) => { m.notices.push(e.data.text); });
            break;
          case "done":
            update((m) => { m.done = e.data; m.streaming = false; if (e.data.answer && !m.text.trim()) m.text = e.data.answer; });
            break;
          case "error":
            update((m) => { m.error = e.data.detail; m.streaming = false; });
            break;
        }
      });
    } catch (err) {
      update((m) => { m.error = err instanceof ApiError ? `${err.status}: ${err.message}` : String(err); m.streaming = false; });
    } finally {
      update((m) => { m.streaming = false; });
      setBusy(false);
    }
  };

  const allTools = useMemo(
    () => conv.msgs.flatMap((m, i) => (m.role === "assistant" ? m.tools.map((t) => ({ ...t, q: i })) : [])),
    [conv.msgs],
  );

  if (cfg && cfg.copilot && !cfg.copilot.enabled)
    return (
      <Card title="Copilot">
        <p className="text-sm text-ink-3">No model key in this pod — ./scripts/90-ai-secret.sh stores it in secret/ai-keys; mission-control reads it at start.</p>
      </Card>
    );

  return (
    <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_420px]">
      <section className="flex min-h-[70vh] flex-col rounded-lg border border-line bg-surface-2">
        <header className="flex flex-wrap items-center justify-between gap-2 border-b border-line px-4 py-2.5">
          <div className="flex items-center gap-2">
            <h2 className="text-sm font-semibold text-ink-2">Copilot</h2>
            {conv.incident && (
              <a href={href("incidents", conv.incident)} className="font-mono text-xs text-info hover:underline">
                investigating {conv.incident}
              </a>
            )}
            {cfg?.copilot && <span className="text-[11px] text-ink-3">{cfg.copilot.model} · {cfg.copilot.tool_budget} tool calls per question</span>}
          </div>
          <Button size="sm" variant="ghost" disabled={busy} onClick={() => { store.delete(key); setConv(fresh()); }}>
            New conversation
          </Button>
        </header>

        <div className="flex-1 space-y-4 overflow-y-auto p-4">
          {conv.msgs.length === 0 && (
            <div>
              <p className="text-sm text-ink-3">
                Read-only tools over the platform, plus <span className="text-ink-2">propose_action</span> — it can recommend an action; only a human in the banner can approve it.
              </p>
              <p className="mt-3 text-xs text-ink-3">The Day 11 warm-up:</p>
              <div className="mt-1 flex flex-wrap gap-2">
                {WARMUP.map((q) => (
                  <button key={q} onClick={() => void ask(q)} className="rounded-full border border-line px-3 py-1 text-left text-xs text-ink-2 hover:bg-surface-3">
                    {q}
                  </button>
                ))}
              </div>
            </div>
          )}
          {conv.msgs.map((m, i) => (m.role === "user" ? <UserBubble key={i} text={m.text} /> : <Answer key={i} m={m} />))}
          <div ref={bottom} />
        </div>

        <form
          className="flex gap-2 border-t border-line p-3"
          onSubmit={(e) => {
            e.preventDefault();
            void ask(input);
          }}
        >
          <textarea
            rows={2}
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                void ask(input);
              }
            }}
            placeholder="Ask about the platform… (Enter to send, Shift+Enter for a new line)"
            className="flex-1 resize-none rounded-md border border-line bg-surface px-3 py-2 text-sm text-ink placeholder:text-ink-3"
          />
          <Button type="submit" variant="primary" disabled={busy || !input.trim()}>
            {busy ? "Working…" : "Ask"}
          </Button>
        </form>
      </section>

      <aside className="rounded-lg border border-line bg-surface-2" aria-label="Tool trail">
        <header className="border-b border-line px-4 py-2.5">
          <h2 className="text-sm font-semibold text-ink-2">Tool trail · {allTools.length}</h2>
          <p className="text-[11px] text-ink-3">Every query the model ran, exactly as it ran it. No trail, no evidence.</p>
        </header>
        <ol className="max-h-[75vh] space-y-2 overflow-y-auto p-3">
          {allTools.length === 0 && <li className="text-xs text-ink-3">Nothing yet.</li>}
          {allTools.map((t) => (
            <ToolCard key={t.id} t={t} />
          ))}
        </ol>
      </aside>
    </div>
  );
}

function UserBubble({ text }: { text: string }) {
  return (
    <div className="flex justify-end">
      <p className="max-w-[80%] whitespace-pre-wrap rounded-lg bg-info/20 px-3 py-2 text-sm text-ink">{text}</p>
    </div>
  );
}

/** The last n characters, starting at a word boundary. */
function tail(s: string, n: number) {
  if (s.length <= n) return s;
  const t = s.slice(-n);
  const cut = t.indexOf(" ");
  return "…" + (cut >= 0 && cut < 30 ? t.slice(cut + 1) : t);
}

function Answer({ m }: { m: Extract<Msg, { role: "assistant" }> }) {
  const [showThinking, setShowThinking] = useState(false);
  const proposals = m.tools.filter((t) => t.name === "propose_action" && !t.running);
  const running = m.tools.find((t) => t.running);
  return (
    <div className="max-w-[92%] rounded-lg border border-line bg-surface p-3">
      {m.thinking && (
        <button onClick={() => setShowThinking((s) => !s)} className="mb-1 block w-full text-left text-xs italic text-ink-3">
          {m.streaming && !m.text ? "Thinking… " : "Thought · "}
          {showThinking ? m.thinking : tail(m.thinking.replace(/ · $/, ""), 160)}
        </button>
      )}
      {m.streaming && !m.thinking && !m.text && <p className="text-xs italic text-ink-3">Thinking…</p>}
      {running && <p className="text-xs text-ink-3">↳ calling {running.name}…</p>}
      {m.text && <Markdown text={m.text} />}
      {proposals.map((p) => (
        <div key={p.id} className="mt-2 rounded-md border border-warning/60 bg-surface-3 p-2 text-xs">
          <span className="font-semibold text-ink">Proposed:</span>{" "}
          <code className="font-mono text-ink-2">
            {String(p.input.action_id)} {JSON.stringify(p.input.params ?? {})}
          </code>
          <span className="block text-ink-3">
            {p.error ? `refused — ${p.summary}` : "waiting in the approvals banner — a human decides; nothing has run."}
          </span>
        </div>
      ))}
      {m.notices.map((n, i) => (
        <p key={i} className="mt-1 text-[11px] text-ink-3">ⓘ {n}</p>
      ))}
      {m.error && <p className="mt-2 text-sm text-ink"><span aria-hidden>⚠ </span>{m.error}</p>}
      {m.done && (
        <>
          <p className="mt-2 text-[11px] text-ink-3">
            {m.done.tool_calls} tool call{m.done.tool_calls === 1 ? "" : "s"} · {(m.done.ms / 1000).toFixed(1)} s · {m.done.tokens_in.toLocaleString()}→
            {m.done.tokens_out.toLocaleString()} tokens{m.done.cache_read ? ` (${m.done.cache_read.toLocaleString()} cached)` : ""}
            {m.done.cost_usd != null ? ` · $${m.done.cost_usd.toFixed(4)}` : ""} · {m.done.model}
            {m.done.note ? ` · ${m.done.note}` : ""}
          </p>
          <Grade turnId={m.done.turn_id} />
        </>
      )}
    </div>
  );
}

function Grade({ turnId }: { turnId: number }) {
  const [verdict, setVerdict] = useState<"up" | "down" | null>(null);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const toast = useToast();
  const qc = useQueryClient();
  const send = async (v: "up" | "down") => {
    setBusy(true);
    try {
      await post("/api/eval", { turn_id: turnId, verdict: v, comment: note });
      setVerdict(v);
      qc.invalidateQueries({ queryKey: ["evals", "all"] });
      toast({ tone: "good", title: `Graded ${v === "up" ? "👍" : "👎"}`, detail: "eval row written — see Evals" });
    } catch (e) {
      toast({ tone: "critical", title: "Grade refused", detail: String(e) });
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="mt-2 flex flex-wrap items-center gap-2 text-xs">
      <Button size="sm" variant={verdict === "up" ? "primary" : "secondary"} disabled={busy} onClick={() => void send("up")} aria-label="Good answer">👍</Button>
      <Button size="sm" variant={verdict === "down" ? "danger" : "secondary"} disabled={busy} onClick={() => void send("down")} aria-label="Bad answer">👎</Button>
      <input value={note} onChange={(e) => setNote(e.target.value)} placeholder="one line: what it got right or wrong"
        className="min-w-48 flex-1 rounded border border-line bg-surface px-2 py-1 text-xs text-ink placeholder:text-ink-3" />
      {verdict && <Badge tone="good">graded</Badge>}
    </div>
  );
}

function ToolCard({ t }: { t: Tool }) {
  const [open, setOpen] = useState(false);
  const arg = (t.input.query ?? t.input.spl ?? t.input.args ?? t.input.symptoms ?? t.input.incident_id ?? t.input.service ?? t.input.action_id) as string | undefined;
  return (
    <li className={cx("rounded-md border bg-surface p-2 text-xs", t.error ? "border-critical/70" : t.name === "propose_action" ? "border-warning/70" : "border-line")}>
      <div className="flex items-center justify-between gap-2">
        <span className="font-mono font-semibold text-ink">{t.name}</span>
        <span className="tabular text-ink-3">{t.running ? "…" : `${t.ms} ms`}</span>
      </div>
      {arg !== undefined && <code className="mt-1 block whitespace-pre-wrap break-all font-mono text-[11px] text-ink-2">{String(arg)}</code>}
      {t.input.earliest ? <span className="text-[11px] text-ink-3">earliest {String(t.input.earliest)}</span> : null}
      <p className={cx("mt-1", t.error ? "text-ink" : "text-ink-3")}>{t.error ? "⚠ " : "→ "}{t.summary}</p>
      {t.result && (
        <button onClick={() => setOpen((o) => !o)} className="mt-1 text-[11px] text-info hover:underline">
          {open ? "hide result" : "show result"}
        </button>
      )}
      {open && t.result && <pre className="mt-1 max-h-60 overflow-auto whitespace-pre-wrap break-all rounded bg-surface-3 p-2 font-mono text-[10px] text-ink-2">{t.result}</pre>}
    </li>
  );
}
