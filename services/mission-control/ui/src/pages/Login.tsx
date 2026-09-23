// The login prompt: a name (for the audit row) and the bearer token. Deliberately minimal
// (PDF Day 21 Step 4) — in a company this is OIDC, and the swap is session.ts + app.py caller().
// The token is checked against the API before it is kept; it is kept only for this tab.
import { useState } from "react";
import { api, ApiError } from "../lib/api";
import { OPERATOR_RE, setSession } from "../lib/session";
import { Button } from "../components/ui";

export function Login({ onDone }: { onDone: () => void }) {
  const [operator, setOperator] = useState("");
  const [token, setToken] = useState("");
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setErr(null);
    if (!OPERATOR_RE.test(operator.trim())) {
      setErr("Name: letters, digits, spaces and . _ @ - (up to 60).");
      return;
    }
    setBusy(true);
    try {
      await api("/api/config", { token: token.trim(), operator: operator.trim() });
      setSession({ token: token.trim(), operator: operator.trim() });
      onDone();
    } catch (e2) {
      setErr(e2 instanceof ApiError && e2.status === 401 ? "That token was refused." : `Could not reach Mission Control: ${String(e2)}`);
    } finally {
      setBusy(false);
    }
  };

  return (
    <main className="flex min-h-screen items-center justify-center p-4">
      <form onSubmit={submit} className="w-full max-w-sm rounded-lg border border-line bg-surface-2 p-6">
        <h1 className="text-lg font-semibold">Mission Control</h1>
        <p className="mt-1 text-sm text-ink-3">bhn-sim · every action you take here is audited under your name.</p>
        <label className="mt-5 block text-sm text-ink-2">
          Your name
          <input
            autoFocus
            autoComplete="username"
            value={operator}
            onChange={(e) => setOperator(e.target.value)}
            className="mt-1 block w-full rounded-md border border-line bg-surface px-3 py-2 text-ink"
          />
        </label>
        <label className="mt-3 block text-sm text-ink-2">
          Access token
          <input
            type="password"
            autoComplete="current-password"
            value={token}
            onChange={(e) => setToken(e.target.value)}
            className="mt-1 block w-full rounded-md border border-line bg-surface px-3 py-2 font-mono text-ink"
          />
        </label>
        <p className="mt-1 text-[11px] text-ink-3">
          <code>./scripts/220-mc-open.sh</code> puts it on your clipboard without printing it.
        </p>
        {err && (
          <p role="alert" className="mt-3 text-sm text-ink">
            <span aria-hidden>⚠ </span>
            {err}
          </p>
        )}
        <Button type="submit" variant="primary" className="mt-5 w-full" disabled={busy || !operator || !token}>
          {busy ? "Checking…" : "Sign in"}
        </Button>
      </form>
    </main>
  );
}
