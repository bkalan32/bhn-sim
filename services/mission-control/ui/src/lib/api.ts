// Every call the UI makes goes through here: the bearer token, the operator's name for the
// audit row, and the entrance ("button" — this is the UI). Nothing else in the app calls fetch.
import { getSession, clearSession } from "./session";

export type Entrance = "button" | "command";

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export async function api<T>(
  path: string,
  opts: { method?: "GET" | "POST"; body?: unknown; entrance?: Entrance; token?: string; operator?: string } = {},
): Promise<T> {
  const s = getSession();
  const token = opts.token ?? s?.token;
  const operator = opts.operator ?? s?.operator ?? "";
  if (!token) throw new ApiError(401, "not signed in");
  const r = await fetch(path, {
    method: opts.method ?? "GET",
    headers: {
      Authorization: `Bearer ${token}`,
      "X-Operator": operator,
      "X-Entrance": opts.entrance ?? "button",
      ...(opts.body !== undefined ? { "Content-Type": "application/json" } : {}),
    },
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });
  const text = await r.text();
  let data: unknown = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }
  if (!r.ok) {
    if (r.status === 401 && !opts.token) {
      clearSession();
      window.dispatchEvent(new Event("mc:signed-out"));
    }
    const detail =
      data && typeof data === "object" && "detail" in data ? String((data as { detail: unknown }).detail) : text.slice(0, 300);
    throw new ApiError(r.status, detail || `HTTP ${r.status}`);
  }
  return data as T;
}

export const post = <T>(path: string, body: unknown = {}, entrance: Entrance = "button") =>
  api<T>(path, { method: "POST", body, entrance });
