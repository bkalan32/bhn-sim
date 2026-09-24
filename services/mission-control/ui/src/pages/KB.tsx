// Day 24 Step 4 — the knowledge base as cards: symptoms, the discriminating checks (each one a
// "run in copilot" link that pre-fills the question), the fix, and the incidents it was learned from.
// Read-only here: the KB is kb/*.md in git, shipped as a ConfigMap by scripts/172-kb.sh — an edit is a
// commit, and "Add a KB entry from this incident" on the incident page starts one.
import { useEffect } from "react";
import { useConfig, useKB } from "../lib/queries";
import { href } from "../lib/router";
import type { KBEntry } from "../lib/types";
import { setCopilotDraft } from "./copilotDraft";
import { Markdown } from "../components/markdown";
import { Badge, Card, ExtLink, Skeleton, TierBadge, Unavailable, cx } from "../components/ui";

export function KB({ id }: { id?: string }) {
  const { data, isLoading, error } = useKB();
  const { data: cfg } = useConfig();
  useEffect(() => {
    if (id && data) document.getElementById(`kb-${id}`)?.scrollIntoView({ block: "start" });
  }, [id, data]);
  if (isLoading) return <Skeleton className="h-96" />;
  if (error || !data) return <Unavailable what="KB" error={String(error)} />;
  return (
    <div className="flex flex-col gap-4">
      <p className="text-xs text-ink-3">
        {data.length} entries from ConfigMap <span className="font-mono">kb</span> — what the incident bot's hypothesis cites.
        Edits are commits to <span className="font-mono">kb/*.md</span>, then <span className="font-mono">./scripts/172-kb.sh</span>.
      </p>
      <div className="grid gap-4 xl:grid-cols-2">
        {data.map((e) => (
          <KBCard key={e.file} e={e} selected={e.id === id} repo={cfg?.repo_url} />
        ))}
      </div>
    </div>
  );
}

function KBCard({ e, selected, repo }: { e: KBEntry; selected: boolean; repo?: string }) {
  const ask = (check: string) => {
    setCopilotDraft(`Run this discriminating check from ${e.id} (${e.title}) and tell me what it shows right now: ${check}`);
    window.location.hash = href("copilot");
  };
  if (e.error) {
    return (
      <Card title={<span className="font-mono">{e.file}</span>} tone="critical">
        <p className="text-sm text-ink">This entry does not parse, so the bot cannot cite it:</p>
        <p className="mt-1 font-mono text-xs text-critical">{e.error}</p>
      </Card>
    );
  }
  return (
    <section id={`kb-${e.id}`} className={cx("rounded-lg border bg-surface-2", selected ? "border-info" : "border-line")}>
      <header className="flex flex-wrap items-center gap-2 border-b border-line px-4 py-2.5">
        <span className="font-mono text-xs text-info">{e.id}</span>
        <h2 className="text-sm font-semibold text-ink">{e.title}</h2>
        <span className="ml-auto flex items-center gap-1">
          <TierBadge tier={e.tier} />
          {e.services.map((s) => <Badge key={s}>{s}</Badge>)}
        </span>
      </header>
      <div className="space-y-3 p-4 text-sm">
        <div>
          <h3 className="mb-1 text-xs uppercase tracking-wider text-ink-3">Symptoms</h3>
          <ul className="list-disc space-y-1 pl-5 text-ink-2">{e.symptoms.map((s, i) => <li key={i}>{s}</li>)}</ul>
        </div>
        <div>
          <h3 className="mb-1 text-xs uppercase tracking-wider text-ink-3">Discriminating checks</h3>
          <ul className="space-y-2">
            {e.checks.map((c, i) => (
              <li key={i} className="rounded-md border border-line bg-surface p-2">
                <code className="block whitespace-pre-wrap break-words font-mono text-[11px] text-ink-2">{c}</code>
                <button className="mt-1 text-xs text-info hover:underline" onClick={() => ask(c)}>run in copilot →</button>
              </li>
            ))}
          </ul>
        </div>
        {e.fix && (
          <p className="rounded-md border border-line bg-surface p-3 text-ink-2">
            <span className="font-semibold text-ink">Fix: </span>
            {e.fix}
          </p>
        )}
        <div className="flex flex-wrap items-center gap-1 text-xs">
          <span className="text-ink-3">Learned from</span>
          {e.learned_from.map((inc) =>
            repo && /^INC-\d{4}$/.test(inc) ? (
              <ExtLink key={inc} href={`${repo}/incidents/${inc}.md`} className="rounded-full border border-line px-2 py-0.5 font-mono">{inc}</ExtLink>
            ) : (
              <span key={inc} className="rounded-full border border-line px-2 py-0.5 font-mono">{inc}</span>
            ),
          )}
        </div>
        {e.notes && (
          <details className="text-ink-2">
            <summary className="cursor-pointer text-xs text-ink-3">Notes</summary>
            <Markdown text={e.notes.replace(/^Notes:\s*/, "")} />
          </details>
        )}
      </div>
    </section>
  );
}
