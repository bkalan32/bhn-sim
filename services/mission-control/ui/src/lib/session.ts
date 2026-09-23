// Who is at the keyboard. The token lives in sessionStorage: per tab, gone when the tab closes,
// never in localStorage (which outlives the browser session) and never in a cookie (which the
// browser would attach to requests this page did not make). In a company this whole file is an
// OIDC login; the swap is here and in app.py's `caller()` (README: "Auth").
export type Session = { token: string; operator: string };

const KEY = "mc.session";
let memory: Session | null = null; // fallback when storage is blocked

export function getSession(): Session | null {
  try {
    const raw = sessionStorage.getItem(KEY);
    if (raw) return JSON.parse(raw) as Session;
  } catch {
    /* storage unavailable: fall through to memory */
  }
  return memory;
}

export function setSession(s: Session) {
  memory = s;
  try {
    sessionStorage.setItem(KEY, JSON.stringify(s));
  } catch {
    /* memory only */
  }
}

export function clearSession() {
  memory = null;
  try {
    sessionStorage.removeItem(KEY);
  } catch {
    /* nothing to clear */
  }
}

// The same rule the API enforces on X-Operator (app.py caller()).
export const OPERATOR_RE = /^[A-Za-z0-9_.@ -]{1,60}$/;
