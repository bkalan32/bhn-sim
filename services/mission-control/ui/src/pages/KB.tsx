// The knowledge base (Day 17) — where the hypothesis's KB chips land. Read-only here: the KB is
// kb/*.md in git, shipped as a ConfigMap by scripts/172-kb.sh; edits go through a PR.
import { useKB } from "../lib/queries";
import { href } from "../lib/router";
import { Badge, Card, Skeleton, TierBadge, Unavailable, cx } from "../components/ui";

export function KB({ id }: { id?: string }) {
  const { data, isLoading, error } = useKB();
  const current = data?.find((e) => e.id === id) ?? null;
  return (
    <div className="grid gap-4 lg:grid-cols-[320px_minmax(0,1fr)]">
      <Card title={`Knowledge base${data ? ` · ${data.length}` : ""}`}>
        {isLoading && <Skeleton className="h-40" />}
        {error && <Unavailable what="KB" error={String(error)} />}
        <ul className="-mx-2 flex flex-col">
          {(data ?? []).map((e) => (
            <li key={e.file}>
              <a href={href("kb", e.id ?? e.file)} className={cx("block rounded px-2 py-2 hover:bg-surface-3", e.id === id && "bg-surface-3")}>
                <div className="flex items-center gap-2">
                  <span className="font-mono text-xs text-info">{e.id}</span>
                  <TierBadge tier={e.tier} />
                </div>
                <p className="text-sm text-ink">{e.title}</p>
              </a>
            </li>
          ))}
        </ul>
      </Card>
      <Card title={current ? `${current.id} — ${current.title}` : "Pick an entry"}>
        {current ? (
          <>
            <div className="mb-3 flex flex-wrap gap-2">
              <TierBadge tier={current.tier} />
              {current.services.map((s) => <Badge key={s}>{s}</Badge>)}
            </div>
            {current.fix && (
              <p className="mb-3 rounded-md border border-line bg-surface p-3 text-sm text-ink-2">
                <span className="font-semibold text-ink">Fix: </span>
                {current.fix}
              </p>
            )}
            <pre className="overflow-x-auto whitespace-pre-wrap rounded-md border border-line bg-surface p-3 font-mono text-xs leading-relaxed text-ink-2">
              {current.markdown}
            </pre>
          </>
        ) : (
          <p className="text-sm text-ink-3">{id ? `No entry ${id} in the KB ConfigMap.` : "Entries are what the incident bot's hypothesis cites."}</p>
        )}
      </Card>
    </div>
  );
}
