// The handful of primitives the screens are built from, in shadcn/ui's style (Tailwind classes
// on plain elements, variants as props). shadcn is a generator that copies components like
// these into your repo; four of them did not need the generator (CORRECTIONS-DAY22 D3).
import { useState, type ButtonHTMLAttributes, type ReactNode } from "react";
import type { Tone } from "../lib/format";

export function cx(...c: (string | false | null | undefined)[]) {
  return c.filter(Boolean).join(" ");
}

const TONE_BG: Record<Tone, string> = {
  good: "bg-good",
  warning: "bg-warning",
  critical: "bg-critical",
  info: "bg-info",
  neutral: "bg-ink-3",
};
const TONE_BORDER: Record<Tone, string> = {
  good: "border-good",
  warning: "border-warning",
  critical: "border-critical",
  info: "border-info",
  neutral: "border-line",
};
const TONE_LEFT: Record<Tone, string> = {
  good: "border-l-good",
  warning: "border-l-warning",
  critical: "border-l-critical",
  info: "border-l-info",
  neutral: "border-l-ink-3",
};
const TONE_ICON: Record<Tone, string> = { good: "✓", warning: "!", critical: "✕", info: "•", neutral: "·" };

export const toneBorder = (t: Tone) => TONE_BORDER[t];
export const toneBg = (t: Tone) => TONE_BG[t];
/** A tile with a status accent on its left edge only. */
export const accent = (t: Tone) => cx("border border-line border-l-4", TONE_LEFT[t]);

export function Card({ title, actions, children, className, tone }: {
  title?: ReactNode; actions?: ReactNode; children: ReactNode; className?: string; tone?: Tone;
}) {
  return (
    <section className={cx("rounded-lg border bg-surface-2", tone ? TONE_BORDER[tone] : "border-line", className)}>
      {(title || actions) && (
        <header className="flex items-center justify-between gap-2 border-b border-line px-4 py-2.5">
          <h2 className="text-sm font-semibold text-ink-2">{title}</h2>
          {actions && <div className="flex items-center gap-2">{actions}</div>}
        </header>
      )}
      <div className="p-4">{children}</div>
    </section>
  );
}

type Variant = "primary" | "secondary" | "danger" | "ghost";
const VARIANT: Record<Variant, string> = {
  primary: "bg-info text-white hover:brightness-110",
  secondary: "bg-surface-3 text-ink border border-line hover:bg-line",
  danger: "bg-critical text-white hover:brightness-110",
  ghost: "text-ink-2 hover:bg-surface-3 hover:text-ink",
};

export function Button({ variant = "secondary", size = "md", className, ...rest }: ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: Variant; size?: "sm" | "md";
}) {
  return (
    <button
      {...rest}
      className={cx(
        "inline-flex items-center justify-center gap-1.5 rounded-md font-medium transition disabled:cursor-not-allowed disabled:opacity-50",
        size === "sm" ? "h-7 px-2.5 text-xs" : "h-9 px-3.5 text-sm",
        VARIANT[variant],
        className,
      )}
    />
  );
}

/** A status marker: coloured dot + icon + word. Colour is never the only carrier. */
export function Status({ tone, label, className }: { tone: Tone; label: string; className?: string }) {
  return (
    <span className={cx("inline-flex items-center gap-1.5 text-xs font-medium text-ink-2", className)}>
      <span aria-hidden className={cx("inline-flex h-4 w-4 items-center justify-center rounded-full text-[10px] font-bold text-surface", TONE_BG[tone])}>
        {TONE_ICON[tone]}
      </span>
      {label}
    </span>
  );
}

export function Badge({ children, tone = "neutral", className, title }: { children: ReactNode; tone?: Tone; className?: string; title?: string }) {
  return (
    <span title={title} className={cx("inline-flex items-center gap-1 rounded border px-1.5 py-0.5 text-[11px] font-medium text-ink-2", TONE_BORDER[tone], className)}>
      {tone !== "neutral" && <span aria-hidden className={cx("h-1.5 w-1.5 rounded-full", TONE_BG[tone])} />}
      {children}
    </span>
  );
}

export function TierBadge({ tier }: { tier: number | string | null | undefined }) {
  const t = String(tier ?? "?");
  const tone: Tone = t === "1" ? "info" : t === "2" ? "warning" : t === "3" ? "neutral" : "neutral";
  return <Badge tone={tone}>tier {t}</Badge>;
}

export function Skeleton({ className }: { className?: string }) {
  return <div className={cx("animate-pulse rounded bg-surface-3", className)} />;
}

export function Unavailable({ what, error }: { what: string; error?: string }) {
  return (
    <p className="text-xs text-ink-3" title={error}>
      <span aria-hidden>⚠ </span>
      {what} unavailable{error ? ` — ${error.slice(0, 120)}` : ""}
    </p>
  );
}

export function CopyButton({ text, label = "Copy" }: { text: string; label?: string }) {
  const [done, setDone] = useState(false);
  return (
    <Button
      size="sm"
      variant="ghost"
      aria-label={`${label} to clipboard`}
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(text);
        } catch {
          const ta = document.createElement("textarea");
          ta.value = text;
          document.body.appendChild(ta);
          ta.select();
          document.execCommand("copy");
          ta.remove();
        }
        setDone(true);
        window.setTimeout(() => setDone(false), 1500);
      }}
    >
      {done ? "Copied" : label}
    </Button>
  );
}

export function ExtLink({ href, children, className }: { href: string; children: ReactNode; className?: string }) {
  return (
    <a href={href} target="_blank" rel="noreferrer noopener" className={cx("text-info underline-offset-2 hover:underline", className)}>
      {children}
      <span aria-hidden className="ml-0.5 text-[10px]">↗</span>
    </a>
  );
}
