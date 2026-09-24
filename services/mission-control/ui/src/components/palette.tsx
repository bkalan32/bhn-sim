// Day 23 Step 3 — the command palette: Ctrl+K (⌘K) anywhere. It searches screens, the action catalog
// and the knowledge base; slash commands are aliases. It is the THIRD entrance to the same catalog:
// choosing an action opens the same confirmation card as the button, the request carries
// X-Entrance: command, and nothing here skips a tier — a /drill is a tier-2 request like any other.
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useActions, useKB } from "../lib/queries";
import { href, useRoute } from "../lib/router";
import type { Action } from "../lib/types";
import { setCopilotDraft } from "../pages/copilotDraft";
import { ConfirmCard } from "./actions";
import { cx, TierBadge } from "./ui";

type Item = { key: string; group: "Screen" | "Action" | "Knowledge base" | "Command"; label: string; hint?: string; run: () => void; tier?: number };
type Pending = { action: Action; fixed: Record<string, unknown>; reason?: string };

const Ctx = createContext<{ open: () => void }>({ open: () => undefined });
export const usePalette = () => useContext(Ctx);

const SCREENS: [string, string][] = [["Overview", ""], ["Incidents", "incidents"], ["Copilot", "copilot"], ["Game Day", "gameday"],
  ["KPIs", "kpis"], ["Reports", "reports"], ["Knowledge base", "kb"], ["Audit log", "audit"], ["Evals", "evals"]];

// /drill <name> — the Day 2-5 faults, as tier-2 requests. /revert <name> puts the knob back to its baseline.
const DRILLS: Record<string, { target: string; knob: string; value: string; what: string }> = {
  fraud: { target: "activation", knob: "FRAUD_SVC_DOWN", value: "true", what: "fraud dependency down (kb-001)" },
  latency: { target: "activation", knob: "BASE_LATENCY_MS", value: "400", what: "activation +400 ms" },
  errors: { target: "activation", knob: "ERROR_RATE", value: "0.3", what: "activation 30 % errors" },
  email: { target: "egift", knob: "EMAIL_FAIL_RATE", value: "0.5", what: "email partner 50 % failures (kb-003)" },
  settlement: { target: "settlement", knob: "SETTLEMENT_FAIL_MODE", value: "crash", what: "settlement job crashes" },
  traffic: { target: "loadgen-activation", knob: "RATE_MULTIPLIER", value: "0", what: "activation traffic off" },
};

const SLASH = [
  ["/drill fraud|latency|errors|email|settlement|traffic", "request a fault (tier 2)"],
  ["/revert <drill>", "request the knob back to its baseline (tier 2)"],
  ["/rollback <service>", "roll back one revision (tier 2)"],
  ["/scale <service> <0-4>", "scale a Deployment (tier 2)"],
  ["/note <text>", "note on the incident you are looking at (tier 1)"],
  ["/report", "generate the daily ops report (tier 1)"],
  ["/reset", "every fault knob back to baseline; ends a game day (tier 1)"],
  ["/gameday <scenario>", "run a scenario sealed (tier 2)"],
  ["/kb <words>", "search the knowledge base"],
  ["/ask <question>", "ask the copilot"],
];

export function PaletteProvider({ children }: { children: ReactNode }) {
  const [isOpen, setOpen] = useState(false);
  const open = useCallback(() => setOpen(true), []);
  useEffect(() => {
    const on = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setOpen((o) => !o);
      }
    };
    window.addEventListener("keydown", on);
    return () => window.removeEventListener("keydown", on);
  }, []);
  return (
    <Ctx.Provider value={{ open }}>
      {children}
      {isOpen && <Palette onClose={() => setOpen(false)} />}
    </Ctx.Provider>
  );
}

function Palette({ onClose }: { onClose: () => void }) {
  const [q, setQ] = useState("");
  const [sel, setSel] = useState(0);
  const [pending, setPending] = useState<Pending | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const { data: catalog } = useActions();
  const { data: kb } = useKB();
  const route = useRoute();
  const incident = route[0] === "incidents" && route[1] ? route[1] : null;
  const inputRef = useRef<HTMLInputElement>(null);
  const byId = (id: string) => catalog?.find((a) => a.id === id);
  const go = (h: string) => { window.location.hash = h; onClose(); };
  const act = (id: string, fixed: Record<string, unknown> = {}, reason?: string) => {
    const a = byId(id);
    if (a) setPending({ action: a, fixed, reason });
  };

  const items: Item[] = useMemo(() => {
    const t = q.trim();
    if (t.startsWith("/")) {
      const [cmd, ...rest] = t.slice(1).split(/\s+/);
      const arg = rest.join(" ");
      const out: Item[] = [];
      const add = (label: string, run: () => void, hint?: string) => out.push({ key: label, group: "Command", label, hint, run });
      switch (cmd) {
        case "drill":
        case "revert":
          Object.entries(DRILLS).filter(([n]) => !arg || n.startsWith(arg)).forEach(([n, d]) => {
            const base = (byId("set_fault")?.knobs?.[d.target]?.[d.knob]?.baseline ?? "") as string;
            const value = cmd === "drill" ? d.value : base;
            add(`/${cmd} ${n}`, () => act("set_fault", { target: d.target, knob: d.knob, value }, cmd === "drill" ? `drill: ${d.what}` : `revert: ${n} back to baseline`),
              `${d.target} ${d.knob}=${value}${cmd === "drill" ? ` — ${d.what}` : " (baseline)"}`);
          });
          break;
        case "rollback":
          (byId("rollback")?.services ?? []).filter((s) => !arg || s.startsWith(arg)).forEach((s) => add(`/rollback ${s}`, () => act("rollback", { service: s })));
          break;
        case "scale": {
          const [svc, n] = rest;
          (byId("scale")?.services ?? []).filter((s) => !svc || s.startsWith(svc)).forEach((s) =>
            add(`/scale ${s}${n ? ` ${n}` : ""}`, () => act("scale", n ? { service: s, replicas: n } : { service: s })));
          break;
        }
        case "note":
          if (!incident) add("/note — open an incident first", () => setMessage("/note writes to the incident page you are on."));
          else if (arg) add(`/note on ${incident}: “${arg}”`, () => act("note", { incident, text: arg }));
          else add(`/note <text> on ${incident}`, () => undefined);
          break;
        case "report":
          add("/report — generate the daily ops report now", () => act("generate_report"));
          break;
        case "reset":
          add("/reset — every fault knob back to baseline (ends a game day)", () => act("reset_faults"));
          break;
        case "gameday":
          (byId("run_scenario")?.scenarios ?? []).filter((x) => !arg || x.startsWith(arg)).forEach((x) =>
            add(`/gameday ${x}`, () => act("run_scenario", { scenario: x }, `game day: ${x}`), "sealed — the steps stay hidden until Retro"));
          break;
        case "kb":
          (kb ?? []).filter((e) => !arg || `${e.id} ${e.title} ${e.markdown}`.toLowerCase().includes(arg.toLowerCase())).slice(0, 8)
            .forEach((e) => add(`${e.id} — ${e.title}`, () => go(href("kb", e.id ?? "")), `tier ${e.tier}`));
          break;
        case "ask":
          add(`/ask ${arg || "<question>"}`, () => { if (arg) { setCopilotDraft(arg); go(incident ? href("copilot", incident) : href("copilot")); } });
          break;
        default:
          SLASH.filter(([c]) => c.startsWith("/" + (cmd ?? ""))).forEach(([c, h]) => add(c, () => setQ(c.split(/[ |<]/)[0] + " "), h));
      }
      return out;
    }
    const n = t.toLowerCase();
    const hit = (s: string) => !n || s.toLowerCase().includes(n);
    const screens: Item[] = SCREENS.filter(([l]) => hit(`go to ${l}`)).map(([l, k]) => ({ key: `s-${k}`, group: "Screen", label: l, run: () => go(k ? href(k) : "#/") }));
    const acts: Item[] = (catalog ?? []).filter((a) => hit(`${a.title} ${a.id}`)).map((a) => ({
      key: `a-${a.id}`, group: "Action", label: a.title, hint: a.params.length ? a.params.join(", ") : "", tier: a.tier,
      run: () => act(a.id, incident && a.params.includes("incident") ? { incident } : {}),
    }));
    const kbs: Item[] = (kb ?? []).filter((e) => n && hit(`${e.id} ${e.title}`)).slice(0, 6).map((e) => ({
      key: `k-${e.id}`, group: "Knowledge base", label: `${e.id} — ${e.title}`, hint: `tier ${e.tier}`, run: () => go(href("kb", e.id ?? "")),
    }));
    const help: Item[] = n ? [] : [{ key: "help", group: "Command", label: "Type / for commands", hint: "/drill, /rollback, /note, /report, /kb, /ask", run: () => setQ("/") }];
    return [...screens, ...acts, ...kbs, ...help];
  }, [q, catalog, kb, incident]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    setSel(0);
  }, [q]);
  const choose = (i: number) => items[i]?.run();

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center bg-black/60 p-4 pt-[12vh]" onMouseDown={onClose} role="dialog" aria-modal="true" aria-label="Command palette">
      <div className="w-full max-w-xl rounded-lg border border-line bg-surface-2 shadow-2xl" onMouseDown={(e) => e.stopPropagation()}>
        {pending ? (
          <div className="p-3">
            <ConfirmCard action={pending.action} fixed={pending.fixed} entrance="command" reasonDefault={pending.reason ?? ""} autoFocus
              onClose={() => { setPending(null); onClose(); }} />
            <p className="mt-2 text-[11px] text-ink-3">Entrance: command — the same catalog entry, tier and audit row as the button.</p>
          </div>
        ) : (
          <>
            <input
              ref={inputRef}
              autoFocus
              value={q}
              onChange={(e) => { setQ(e.target.value); setMessage(null); }}
              onKeyDown={(e) => {
                if (e.key === "Escape") onClose();
                else if (e.key === "ArrowDown") { e.preventDefault(); setSel((s) => Math.min(s + 1, items.length - 1)); }
                else if (e.key === "ArrowUp") { e.preventDefault(); setSel((s) => Math.max(s - 1, 0)); }
                else if (e.key === "Enter") { e.preventDefault(); choose(sel); }
              }}
              placeholder="Go to…, run an action, search the KB — or / for commands"
              className="w-full rounded-t-lg border-b border-line bg-transparent px-4 py-3 text-sm text-ink placeholder:text-ink-3 focus:outline-none"
            />
            {message && <p className="px-4 py-2 text-xs text-ink-2">{message}</p>}
            <ul className="max-h-[50vh] overflow-y-auto py-1" role="listbox">
              {items.length === 0 && <li className="px-4 py-3 text-sm text-ink-3">Nothing matches.</li>}
              {items.map((it, i) => (
                <li key={it.key} role="option" aria-selected={i === sel}>
                  <button
                    onMouseEnter={() => setSel(i)}
                    onClick={() => choose(i)}
                    className={cx("flex w-full items-center justify-between gap-3 px-4 py-2 text-left text-sm", i === sel ? "bg-surface-3 text-ink" : "text-ink-2")}
                  >
                    <span className="min-w-0">
                      <span className="mr-2 text-[10px] uppercase tracking-wider text-ink-3">{it.group}</span>
                      {it.label}
                      {it.hint && <span className="ml-2 text-xs text-ink-3">{it.hint}</span>}
                    </span>
                    {it.tier && <TierBadge tier={it.tier} />}
                  </button>
                </li>
              ))}
            </ul>
            <p className="border-t border-line px-4 py-2 text-[11px] text-ink-3">↑↓ to move · Enter to choose · Esc to close · every action still goes through its tier</p>
          </>
        )}
      </div>
    </div>
  );
}
