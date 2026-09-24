// POST /api/chat answers as Server-Sent Events. EventSource cannot POST, so this reads the
// response body as a stream and splits it into events itself (blank-line separated, "event:" and
// "data:" fields — the same format sse-starlette writes). Comment lines (": ping") are skipped.
import { getSession } from "./session";
import { ApiError } from "./api";

export type ChatEvent = { event: string; data: any }; // eslint-disable-line @typescript-eslint/no-explicit-any

export async function streamChat(
  body: { message: string; conversation_id?: string | null; incident?: string | null },
  onEvent: (e: ChatEvent) => void,
  signal?: AbortSignal,
): Promise<void> {
  const s = getSession();
  if (!s) throw new ApiError(401, "not signed in");
  const r = await fetch("/api/chat", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${s.token}`,
      "X-Operator": s.operator,
      "X-Entrance": "button",
      "Content-Type": "application/json",
      Accept: "text/event-stream",
    },
    body: JSON.stringify(body),
    signal,
  });
  if (!r.ok || !r.body) {
    const t = await r.text();
    let detail = t.slice(0, 300);
    try {
      detail = JSON.parse(t).detail ?? detail;
    } catch {
      /* not JSON */
    }
    throw new ApiError(r.status, detail);
  }
  const reader = r.body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true }).replace(/\r\n/g, "\n");
    let cut: number;
    while ((cut = buf.indexOf("\n\n")) >= 0) {
      const raw = buf.slice(0, cut);
      buf = buf.slice(cut + 2);
      let event = "message";
      const data: string[] = [];
      for (const line of raw.split("\n")) {
        if (line.startsWith("event:")) event = line.slice(6).trim();
        else if (line.startsWith("data:")) data.push(line.slice(5).replace(/^ /, ""));
      }
      if (!data.length) continue;
      try {
        onEvent({ event, data: JSON.parse(data.join("\n")) });
      } catch {
        onEvent({ event, data: data.join("\n") });
      }
    }
  }
}
