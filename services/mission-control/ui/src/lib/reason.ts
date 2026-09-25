// A reason a person can read later — the same rule as actions.prose_reason on the server
// (CORRECTIONS-DAY24 B7): 10-300 characters and three or more words. The server decides; this only
// keeps the button honest and tells you why it is disabled.
export function reasonCheck(text: string, lo = 10, hi = 300): { ok: boolean; hint: string } {
  const t = text.trim();
  const words = (t.match(/[A-Za-z0-9'-]+/g) ?? []).filter((w) => /[A-Za-z]{2}/.test(w));
  const long = words.some((w) => w.length > 25);
  const ok = t.length >= lo && t.length <= hi && words.length >= 3 && !long;
  const hint = long ? "that is not a word" : `${t.length}/${lo}–${hi} characters · ${words.length}/3+ words`;
  return { ok, hint };
}
