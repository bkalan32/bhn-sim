// Server state. TanStack Query owns caching and polling; the SSE feed (events.tsx) invalidates
// these keys when something changes, so polling is only the safety net — except health, which
// the PDF polls every 15 s (and the feed also pushes every 15 s).
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, post, ApiError } from "./api";
import { useToast } from "../components/toast";
import type { Action, ActionResult, Approval, AuditRow, EvalRow, Incident, IncidentSummary, KBEntry, Overview, UIConfig } from "./types";
import { params } from "./format";

export const useConfig = () => useQuery({ queryKey: ["config"], queryFn: () => api<UIConfig>("/api/config"), staleTime: Infinity });

export const useOverview = () =>
  useQuery({ queryKey: ["overview"], queryFn: () => api<Overview>("/api/overview"), refetchInterval: 15_000 });

export const useActions = () =>
  useQuery({
    queryKey: ["actions"],
    queryFn: () => api<{ actions: Action[] }>("/api/actions").then((d) => d.actions),
    staleTime: Infinity,
  });

export const useApprovals = () =>
  useQuery({ queryKey: ["approvals"], queryFn: () => api<Approval[]>("/api/approvals"), refetchInterval: 15_000 });

export const useIncidents = () =>
  useQuery({ queryKey: ["incidents"], queryFn: () => api<IncidentSummary[]>("/api/incidents"), refetchInterval: 30_000 });

export const useIncident = (id: string) =>
  useQuery({
    queryKey: ["incident", id],
    queryFn: () => api<Incident>(`/api/incidents/${encodeURIComponent(id)}`),
    // Drafts and context are attached by the bot in the background — no event announces them.
    refetchInterval: (q) => (q.state.data?.status === "open" || !q.state.data?.ai_resolution_draft ? 10_000 : 60_000),
  });

export const useKB = () => useQuery({ queryKey: ["kb"], queryFn: () => api<KBEntry[]>("/api/kb"), staleTime: 5 * 60_000 });

export const useAudit = (limit = 10) =>
  useQuery({ queryKey: ["audit", limit], queryFn: () => api<AuditRow[]>(`/api/audit?limit=${limit}`), refetchInterval: 60_000 });

export const useEvals = (incident: string) =>
  useQuery({ queryKey: ["evals", incident], queryFn: () => api<EvalRow[]>(`/api/eval?incident=${encodeURIComponent(incident)}`) });

/** Run a catalog action through the ONE door (POST /api/actions/{id}). Tier 1 executes; tier 2
 *  comes back pending with a token and lands in the approvals banner for the second click. */
export function useRunAction() {
  const toast = useToast();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (v: { id: string; params?: Record<string, unknown>; reason?: string }) =>
      post<ActionResult>(`/api/actions/${encodeURIComponent(v.id)}`, { params: v.params ?? {}, reason: v.reason ?? "" }),
    onSuccess: (r, v) => {
      if (r.status === "pending_approval") {
        toast({ tone: "warning", title: `${v.id} requested — waiting for approval`, detail: `${params(v.params)} · token ${(r as { token: string }).token}` });
      } else if (r.status === "executed") {
        toast({ tone: "good", title: `${v.id} done`, detail: String((r as { detail?: string }).detail ?? "") });
      } else {
        toast({ tone: "critical", title: `${v.id} ${r.status}`, detail: String((r as { detail?: string }).detail ?? "") });
      }
      qc.invalidateQueries({ queryKey: ["approvals"] });
      qc.invalidateQueries({ queryKey: ["audit"] });
    },
    onError: (e, v) => toast({ tone: "critical", title: `${v.id} refused`, detail: e instanceof ApiError ? `${e.status}: ${e.message}` : String(e) }),
  });
}

/** The human's second click. Mission Control's own queue or the remediator's — the API decides. */
export function useDecide() {
  const toast = useToast();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (v: { token: string; approve: boolean }) =>
      post<{ status: string; detail?: unknown; action?: string }>(`/api/approvals/${encodeURIComponent(v.token)}/${v.approve ? "approve" : "decline"}`),
    onSuccess: (r, v) => {
      const failed = r.status === "failed";
      toast({
        tone: failed ? "critical" : v.approve ? "good" : "neutral",
        title: `${r.action ?? "proposal"} ${r.status}`,
        detail: typeof r.detail === "string" ? r.detail : r.detail ? JSON.stringify(r.detail).slice(0, 200) : v.token,
      });
      qc.invalidateQueries({ queryKey: ["approvals"] });
      qc.invalidateQueries({ queryKey: ["overview"] });
      qc.invalidateQueries({ queryKey: ["audit"] });
    },
    onError: (e) => toast({ tone: "critical", title: "Approval failed", detail: e instanceof ApiError ? `${e.status}: ${e.message}` : String(e) }),
  });
}
