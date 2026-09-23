// The live feed column — "the bridge scribe's screen when nobody is scribing". Newest at top.
import { useEffect, useState } from "react";
import { useFeed, type FeedItem } from "../lib/events";
import { cx, toneBg } from "./ui";

const KIND_LABEL: Record<FeedItem["kind"], string> = {
  alert: "ALERT",
  incident: "INCIDENT",
  audit: "ACTION",
  approval: "APPROVAL",
  deploy: "DEPLOY",
  system: "SYSTEM",
};

function clock(ts: number) {
  return new Date(ts * 1000).toISOString().slice(11, 19);
}

export function Feed({ className }: { className?: string }) {
  const { items, status, lastHealthAt } = useFeed();
  const [, tick] = useState(0);
  useEffect(() => {
    const t = window.setInterval(() => tick((x) => x + 1), 5000);
    return () => window.clearInterval(t);
  }, []);
  const stale = lastHealthAt !== null && Date.now() - lastHealthAt > 45_000;
  return (
    <section className={cx("flex min-h-0 flex-col rounded-lg border border-line bg-surface-2", className)} aria-label="Live feed">
      <header className="flex items-center justify-between border-b border-line px-4 py-2.5">
        <h2 className="text-sm font-semibold text-ink-2">Live feed</h2>
        <span className="inline-flex items-center gap-1.5 text-xs text-ink-3">
          <span
            aria-hidden
            className={cx("h-2 w-2 rounded-full", status === "live" && !stale ? "bg-good" : status === "connecting" ? "bg-ink-3" : "bg-warning")}
          />
          {status === "live" && !stale ? "live" : status === "live" ? "quiet >45 s" : status}
        </span>
      </header>
      <ol className="min-h-0 flex-1 overflow-y-auto">
        {items.length === 0 && <li className="px-4 py-6 text-sm text-ink-3">Waiting for the first event…</li>}
        {items.map((i) => (
          <li key={i.key} className="flex gap-3 border-b border-line/60 px-4 py-2.5">
            <span aria-hidden className={cx("mt-1.5 h-2 w-2 shrink-0 rounded-full", toneBg(i.tone))} />
            <div className="min-w-0 flex-1">
              <div className="flex items-baseline justify-between gap-2">
                <span className="text-[10px] font-semibold tracking-wider text-ink-3">{KIND_LABEL[i.kind]}</span>
                <time className="tabular font-mono text-[11px] text-ink-3">{clock(i.ts)}Z</time>
              </div>
              {i.link ? (
                <a href={i.link} className="block break-words text-sm text-ink hover:underline">
                  {i.title}
                </a>
              ) : (
                <p className="break-words text-sm text-ink">{i.title}</p>
              )}
              {i.detail && <p className="break-words text-xs text-ink-3">{i.detail}</p>}
            </div>
          </li>
        ))}
      </ol>
    </section>
  );
}
