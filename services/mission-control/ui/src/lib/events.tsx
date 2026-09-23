// The live feed: ONE EventSource per tab (GET /api/events), fanned out to the screen.
// Everything on screen updates from it without a reload: an event either becomes a feed item,
// refreshes the queries it affects, or both. Health scores arrive every 15 s on the same stream
// (the poller's `health` event) and are written straight into the overview cache.
import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { api } from "./api";
import { getSession } from "./session";
import { params, type Tone } from "./format";
import { href } from "./router";
import type { AuditRow, Overview } from "./types";

export type FeedItem = {
  key: string;
  kind: "alert" | "incident" | "audit" | "approval" | "deploy" | "system";
  ts: number; // epoch seconds
  tone: Tone;
  title: string;
  detail?: string;
  link?: string;
};

type Status = "connecting" | "live" | "reconnecting";
type Ctx = { items: FeedItem[]; status: Status; lastHealthAt: number | null };

const FeedContext = createContext<Ctx>({ items: [], status: "connecting", lastHealthAt: null });
export const useFeed = () => useContext(FeedContext);

const MAX_ITEMS = 200;

/* eslint-disable @typescript-eslint/no-explicit-any */
export function toItem(kind: string, d: any, id: string): FeedItem | null {
  const now = Date.now() / 1000;
  switch (kind) {
    case "alert": {
      const resolved = d.status === "resolved";
      return {
        key: `alert-${id}`,
        kind: "alert",
        ts: now,
        tone: resolved ? "good" : d.severity === "critical" ? "critical" : d.severity === "warning" ? "warning" : "neutral",
        title: `${d.alertname ?? "alert"} ${resolved ? "resolved" : "firing"}`,
        detail: [d.service, d.summary].filter(Boolean).join(" · "),
      };
    }
    case "incident":
      return {
        key: `incident-${id}`,
        kind: "incident",
        ts: now,
        tone: d.event === "opened" ? (d.severity === "critical" ? "critical" : "warning") : "good",
        title: `${d.id} ${d.event}`,
        detail:
          d.event === "opened"
            ? `${d.service ?? "?"} · ${(d.alerts ?? []).join(", ")}`
            : `${d.service ?? "?"}${d.duration_min != null ? ` · ${d.duration_min} min` : ""}`,
        link: href("incidents", d.id),
      };
    case "audit": {
      const r = d as AuditRow;
      const tone: Tone =
        r.result === "ok" ? "info" : r.result === "pending" ? "warning" : r.result === "failed" || r.result === "refused" ? "critical" : "neutral";
      const inc = typeof r.params?.incident === "string" ? (r.params.incident as string) : null;
      return {
        key: `audit-${r.id}`,
        kind: "audit",
        ts: r.ts ?? now,
        tone,
        title: `${r.operator || "?"} · ${r.action} · ${r.result}`,
        detail: `tier ${r.tier} via ${r.entrance}${params(r.params) ? " · " + params(r.params) : ""}`,
        link: inc ? href("incidents", inc) : undefined,
      };
    }
    case "approval": {
      const who = d.by ? ` by ${d.by}` : d.operator ? ` by ${d.operator}` : d.source === "remediator" ? " by remediator" : "";
      return {
        key: `approval-${id}`,
        kind: "approval",
        ts: now,
        tone: d.event === "created" || d.event === "proposed" ? "warning" : d.event === "approved" ? "info" : "neutral",
        title: `${d.action ?? "approval"} ${String(d.event ?? "").replace("remediator-", "")}${who}`,
        detail: [params(d.params), d.reason].filter(Boolean).join(" · "),
        link: d.incident ? href("incidents", d.incident) : undefined,
      };
    }
    case "deploy":
      return {
        key: `deploy-${id}`,
        kind: "deploy",
        ts: d.time_ms ? d.time_ms / 1000 : now,
        tone: d.kind === "rollback" ? "warning" : "info",
        title: `${d.kind} · ${d.service ?? "?"}`,
        detail: d.text ?? "",
      };
    default:
      return null;
  }
}

export function FeedProvider({ children }: { children: ReactNode }) {
  const qc = useQueryClient();
  const [items, setItems] = useState<FeedItem[]>([]);
  const [status, setStatus] = useState<Status>("connecting");
  const [lastHealthAt, setLastHealthAt] = useState<number | null>(null);
  const esRef = useRef<EventSource | null>(null);

  // Seed with the recent audit log, so a fresh tab is not an empty column.
  useEffect(() => {
    api<AuditRow[]>("/api/audit?limit=15")
      .then((rows) => {
        const seeded = rows.map((r) => toItem("audit", r, String(r.id))).filter(Boolean) as FeedItem[];
        setItems((cur) => (cur.length ? cur : seeded));
      })
      .catch(() => undefined);
  }, []);

  useEffect(() => {
    let stopped = false;
    let retry: number | undefined;

    const push = (item: FeedItem | null) => {
      if (!item) return;
      setItems((cur) => (cur.some((i) => i.key === item.key) ? cur : [item, ...cur].slice(0, MAX_ITEMS)));
    };

    const connect = () => {
      const token = getSession()?.token;
      if (!token || stopped) return;
      const es = new EventSource(`/api/events?access_token=${encodeURIComponent(token)}`);
      esRef.current = es;
      es.addEventListener("hello", () => setStatus("live"));
      es.addEventListener("health", (e) => {
        const data = JSON.parse((e as MessageEvent).data);
        setLastHealthAt(Date.now());
        qc.setQueryData<Overview>(["overview"], (old) => (old ? { ...old, health: { ok: true, ms: 0, data } } : old));
      });
      es.addEventListener("alert", (e) => {
        const m = e as MessageEvent;
        push(toItem("alert", JSON.parse(m.data), m.lastEventId));
        qc.invalidateQueries({ queryKey: ["overview"] });
      });
      es.addEventListener("incident", (e) => {
        const m = e as MessageEvent;
        const d = JSON.parse(m.data);
        push(toItem("incident", d, m.lastEventId));
        qc.invalidateQueries({ queryKey: ["overview"] });
        qc.invalidateQueries({ queryKey: ["incidents"] });
        if (d.id) qc.invalidateQueries({ queryKey: ["incident", d.id] });
      });
      es.addEventListener("audit", (e) => {
        const m = e as MessageEvent;
        const d = JSON.parse(m.data) as AuditRow;
        push(toItem("audit", d, m.lastEventId));
        qc.invalidateQueries({ queryKey: ["audit"] });
        const inc = d.params?.incident;
        if (typeof inc === "string") {
          qc.invalidateQueries({ queryKey: ["incident", inc] });
          qc.invalidateQueries({ queryKey: ["evals", inc] });
        }
      });
      es.addEventListener("approval", (e) => {
        const m = e as MessageEvent;
        push(toItem("approval", JSON.parse(m.data), m.lastEventId));
        qc.invalidateQueries({ queryKey: ["approvals"] });
        qc.invalidateQueries({ queryKey: ["overview"] });
      });
      es.addEventListener("deploy", (e) => {
        const m = e as MessageEvent;
        push(toItem("deploy", JSON.parse(m.data), m.lastEventId));
        qc.invalidateQueries({ queryKey: ["overview"] });
      });
      es.onerror = () => {
        setStatus("reconnecting");
        // The browser retries on its own after a network blip; a CLOSED stream (401, the pod
        // restarted mid-response) it does not — reconnect ourselves, gently.
        if (es.readyState === EventSource.CLOSED) {
          es.close();
          retry = window.setTimeout(connect, 5000);
        }
      };
    };

    connect();
    return () => {
      stopped = true;
      window.clearTimeout(retry);
      esRef.current?.close();
    };
  }, [qc]);

  return <FeedContext.Provider value={{ items, status, lastHealthAt }}>{children}</FeedContext.Provider>;
}
