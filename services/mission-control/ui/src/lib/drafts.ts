// The bot's drafts are one text block each with numbered, upper-case headings
// ("1. INTERNAL SUMMARY", "2. STAKEHOLDER UPDATE", …; services/incident-bot/ai.py). Split them so
// each part gets its own copy button — the stakeholder update is pasted somewhere different
// from the internal summary. A draft that does not follow the shape is shown whole.

export type DraftPart = { heading: string; body: string };

// Greedy up to the last capital before "(" or ":" — a lazy match stopped after four letters
// ("INTE" + "RNAL SUMMARY…"), found by rendering the page, not by the type checker.
const HEADING = /^[ \t]*(?:#{1,4}[ \t]*)?\**[ \t]*(\d)\.[ \t]*\**[ \t]*([A-Z][A-Z \-/&']{1,60}[A-Z])[ \t]*\**[ \t]*(?:\([^)\n]*\))?[ \t]*:?[ \t]*\**[ \t]*(.*)$/gm;

export function splitDraft(text: string | undefined | null): DraftPart[] {
  if (!text) return [];
  const marks: { index: number; end: number; heading: string; rest: string }[] = [];
  for (const m of text.matchAll(HEADING)) {
    marks.push({ index: m.index ?? 0, end: (m.index ?? 0) + m[0].length, heading: m[2].trim(), rest: m[3] ?? "" });
  }
  if (marks.length < 2) return [{ heading: "", body: text.trim() }];
  const parts: DraftPart[] = [];
  const pre = text.slice(0, marks[0].index).trim();
  if (pre) parts.push({ heading: "", body: pre });
  marks.forEach((m, i) => {
    const next = i + 1 < marks.length ? marks[i + 1].index : text.length;
    const body = (m.rest + text.slice(m.end, next)).trim();
    parts.push({ heading: titleCase(m.heading), body });
  });
  return parts;
}

function titleCase(s: string): string {
  return s.toLowerCase().replace(/(^|[\s-])([a-z])/g, (_, a: string, b: string) => a + b.toUpperCase());
}

// The hypothesis's confidence line ("5. CONFIDENCE: medium — …") and the KB ids it cites.
export function confidenceOf(text: string | undefined | null): "low" | "medium" | "high" | null {
  if (!text) return null;
  const m = text.match(/CONFIDENCE\**\s*:?\s*\**\s*(low|medium|high)/i);
  return m ? (m[1].toLowerCase() as "low" | "medium" | "high") : null;
}

export function kbCited(text: string | undefined | null): string[] {
  if (!text) return [];
  return [...new Set([...text.matchAll(/\bkb-\d{3}\b/gi)].map((m) => m[0].toLowerCase()))];
}

export const isUnavailable = (text?: string | null) => !text || text.startsWith("(AI draft unavailable");
