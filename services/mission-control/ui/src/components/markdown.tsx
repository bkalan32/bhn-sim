// The AI's drafts arrive as markdown ("## 1. WHAT WE KNOW", "**bold**", ```promql blocks```):
// since the bot moved to claude-sonnet-4-5 the model writes it whether asked or not, and the
// incident page showed the raw `##` and `**`. This renders the small subset the drafts use —
// headings, bold, inline code, fenced code, bullet and numbered lists, and (Day 23, the copilot
// writes them) pipe tables — as React elements.
// No HTML is ever injected: the text is data from a model, and the page has a CSP to keep.
import type { ReactNode } from "react";

function inline(text: string, key: string): ReactNode[] {
  const out: ReactNode[] = [];
  const re = /(\*\*[^*]+\*\*|`[^`]+`)/g;
  let last = 0;
  let i = 0;
  for (const m of text.matchAll(re)) {
    const idx = m.index ?? 0;
    if (idx > last) out.push(text.slice(last, idx));
    const tok = m[0];
    if (tok.startsWith("**")) out.push(<strong key={`${key}-${i++}`} className="font-semibold text-ink">{tok.slice(2, -2)}</strong>);
    else out.push(<code key={`${key}-${i++}`} className="rounded bg-surface-3 px-1 font-mono text-[0.85em] text-ink">{tok.slice(1, -1)}</code>);
    last = idx + tok.length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

export function Markdown({ text }: { text: string }) {
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  const blocks: ReactNode[] = [];
  let list: { ordered: boolean; start: number; items: string[] } | null = null;
  let para: string[] = [];
  let k = 0;

  const flushPara = () => {
    if (para.length) blocks.push(<p key={k++} className="my-2">{inline(para.join(" "), `p${k}`)}</p>);
    para = [];
  };
  const flushList = () => {
    if (!list) return;
    const Tag = list.ordered ? "ol" : "ul";
    blocks.push(
      <Tag key={k++} start={list.ordered ? list.start : undefined} className={list.ordered ? "my-2 list-decimal space-y-1 pl-6" : "my-2 list-disc space-y-1 pl-6"}>
        {list.items.map((it, j) => <li key={j}>{inline(it, `l${k}-${j}`)}</li>)}
      </Tag>,
    );
    list = null;
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const fence = line.match(/^\s*```\s*([\w-]*)\s*$/);
    if (fence) {
      flushPara(); flushList();
      const body: string[] = [];
      i++;
      while (i < lines.length && !/^\s*```\s*$/.test(lines[i])) body.push(lines[i++]);
      blocks.push(
        <pre key={k++} className="my-2 overflow-x-auto rounded-md border border-line bg-surface p-3 font-mono text-xs text-ink">
          {fence[1] && <span className="mb-1 block text-[10px] uppercase tracking-wider text-ink-3">{fence[1]}</span>}
          {body.join("\n")}
        </pre>,
      );
      continue;
    }
    // A pipe table: a header row, a |---|---| separator, then rows (CORRECTIONS-DAY23 N6).
    const cells = (l: string) => l.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((c) => c.trim());
    if (/^\s*\|.*\|\s*$/.test(line) && i + 1 < lines.length && /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$/.test(lines[i + 1])) {
      flushPara(); flushList();
      const head = cells(line);
      const rows: string[][] = [];
      i += 2;
      while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) rows.push(cells(lines[i++]));
      i--;
      blocks.push(
        <div key={k++} className="my-2 overflow-x-auto">
          <table className="w-full border-collapse text-xs">
            <thead>
              <tr>{head.map((c, j) => <th key={j} className="border-b border-line px-2 py-1 text-left font-semibold text-ink-3">{inline(c, `th${k}-${j}`)}</th>)}</tr>
            </thead>
            <tbody>
              {rows.map((r, ri) => (
                <tr key={ri} className="border-b border-line/50">
                  {head.map((_, j) => <td key={j} className="px-2 py-1 align-top">{inline(r[j] ?? "", `td${k}-${ri}-${j}`)}</td>)}
                </tr>
              ))}
            </tbody>
          </table>
        </div>,
      );
      continue;
    }
    const h = line.match(/^\s*(#{1,4})\s+(.*)$/);
    if (h) {
      flushPara(); flushList();
      blocks.push(<h4 key={k++} className="mt-4 mb-1 text-xs font-semibold uppercase tracking-wider text-ink-3">{inline(h[2].replace(/\*\*/g, ""), `h${k}`)}</h4>);
      continue;
    }
    const b = line.match(/^\s*[-*]\s+(.*)$/);
    const n = line.match(/^\s*(\d+)[.)]\s+(.*)$/);   // keep the model's own number: "2." stays 2
    if (b || n) {
      flushPara();
      const ordered = !b;
      if (list && list.ordered !== ordered) flushList();
      if (!list) list = { ordered, start: n ? Number(n[1]) : 1, items: [] };
      list.items.push(b ? b[1] : n![2]);
      continue;
    }
    if (!line.trim()) { flushPara(); flushList(); continue; }
    if (list && /^\s{2,}\S/.test(line)) { list.items[list.items.length - 1] += " " + line.trim(); continue; }
    flushList();
    para.push(line.trim());
  }
  flushPara(); flushList();
  return <div className="text-sm leading-relaxed text-ink-2">{blocks}</div>;
}
