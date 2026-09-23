// "Tier 1: one click, runs immediately, audit row, toast after" — this is the toast.
import { createContext, useCallback, useContext, useState, type ReactNode } from "react";
import type { Tone } from "../lib/format";
import { cx, toneBorder, Status } from "./ui";

type Toast = { id: number; tone: Tone; title: string; detail?: string };
const Ctx = createContext<(t: Omit<Toast, "id">) => void>(() => undefined);
export const useToast = () => useContext(Ctx);

let seq = 0;

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const push = useCallback((t: Omit<Toast, "id">) => {
    const id = ++seq;
    setToasts((cur) => [...cur, { ...t, id }].slice(-4));
    window.setTimeout(() => setToasts((cur) => cur.filter((x) => x.id !== id)), t.tone === "critical" ? 9000 : 5000);
  }, []);
  return (
    <Ctx.Provider value={push}>
      {children}
      <div aria-live="polite" className="pointer-events-none fixed bottom-4 right-4 z-50 flex w-96 max-w-[calc(100vw-2rem)] flex-col gap-2">
        {toasts.map((t) => (
          <div key={t.id} className={cx("pointer-events-auto rounded-lg border-l-4 border bg-surface-3 p-3 shadow-lg", toneBorder(t.tone))}>
            <Status tone={t.tone} label={t.title} className="text-sm text-ink" />
            {t.detail && <p className="mt-1 break-words font-mono text-xs text-ink-2">{t.detail}</p>}
          </div>
        ))}
      </div>
    </Ctx.Provider>
  );
}
