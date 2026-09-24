// The shell: header with the six screens, the pending-approvals banner under it on every page,
// and the page for the current route. Screens not built yet say which day builds them.
import { useEffect, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useRoute, href } from "./lib/router";
import { getSession, clearSession } from "./lib/session";
import { FeedProvider } from "./lib/events";
import { useAudit, useConfig } from "./lib/queries";
import { ApprovalBanner } from "./components/approvals";
import { AuditTable } from "./components/audit";
import { Card, Skeleton, cx } from "./components/ui";
import { Overview } from "./pages/Overview";
import { Incidents } from "./pages/Incidents";
import { Incident } from "./pages/Incident";
import { KB } from "./pages/KB";
import { Login } from "./pages/Login";
import { Copilot } from "./pages/Copilot";
import { Evals } from "./pages/Evals";
import { GameDay } from "./pages/GameDay";
import { KPIs } from "./pages/KPIs";
import { Reports } from "./pages/Reports";
import { PaletteProvider, usePalette } from "./components/palette";
import { ErrorBoundary } from "./components/boundary";

const NAV: { key: string; label: string; day?: number }[] = [
  { key: "", label: "Overview" },
  { key: "incidents", label: "Incidents" },
  { key: "copilot", label: "Copilot" },
  { key: "gameday", label: "Game Day" },
  { key: "kpis", label: "KPIs" },
  { key: "reports", label: "Reports" },
  { key: "kb", label: "Knowledge Base" },
  { key: "evals", label: "Evals" },
  { key: "audit", label: "Audit" },
];

export function App() {
  const [signedIn, setSignedIn] = useState(() => getSession() !== null);
  const qc = useQueryClient();
  useEffect(() => {
    const out = () => {
      qc.clear();
      setSignedIn(false);
    };
    window.addEventListener("mc:signed-out", out);
    return () => window.removeEventListener("mc:signed-out", out);
  }, [qc]);
  if (!signedIn) return <Login onDone={() => setSignedIn(true)} />;
  return (
    <FeedProvider>
      <PaletteProvider>
        <Shell onSignOut={() => { clearSession(); qc.clear(); setSignedIn(false); }} />
      </PaletteProvider>
    </FeedProvider>
  );
}

function Shell({ onSignOut }: { onSignOut: () => void }) {
  const route = useRoute();
  const { data: cfg } = useConfig();
  const section = route[0] ?? "";
  return (
    <div className="min-h-screen">
      <header className="flex flex-wrap items-center gap-x-6 gap-y-2 border-b border-line bg-surface-2 px-4 py-3 sm:px-6">
        <a href="#/" className="flex items-baseline gap-2">
          <span className="text-base font-semibold">Mission Control</span>
          <span className="text-xs text-ink-3">bhn-sim{cfg ? ` · v${cfg.version}` : ""}{cfg?.dry_run ? " · DRY RUN" : ""}</span>
        </a>
        <nav className="flex flex-1 flex-wrap gap-1" aria-label="Screens">
          {NAV.map((n) => (
            <a
              key={n.key}
              href={n.key ? href(n.key) : "#/"}
              aria-current={section === n.key ? "page" : undefined}
              className={cx(
                "rounded-md px-2.5 py-1.5 text-sm",
                section === n.key ? "bg-surface-3 text-ink" : "text-ink-2 hover:bg-surface-3 hover:text-ink",
                n.day ? "text-ink-3" : null,
              )}
            >
              {n.label}
              {n.day && <span className="ml-1 text-[10px] text-ink-3">Day {n.day}</span>}
            </a>
          ))}
        </nav>
        <div className="flex items-center gap-3 text-sm">
          <PaletteHint />
          <span className="text-ink-3">
            as <span className="text-ink-2">{getSession()?.operator}</span>
          </span>
          <button onClick={onSignOut} className="text-ink-3 hover:text-ink">
            Sign out
          </button>
        </div>
      </header>
      <ApprovalBanner />
      <main className="p-4 sm:p-6">
        <ErrorBoundary key={route.join("/")} where={`#/${route.join("/")}`}>
          <Page route={route} />
        </ErrorBoundary>
      </main>
    </div>
  );
}

function Page({ route }: { route: string[] }) {
  const [section, id] = route;
  switch (section ?? "") {
    case "":
      return <Overview />;
    case "incidents":
      return id ? <Incident id={id} key={id} /> : <Incidents />;
    case "kb":
      return <KB id={id} />;
    case "audit":
      return <AuditPage />;
    case "copilot":
      return <Copilot incident={id} key={id ?? "_page"} />;
    case "evals":
      return <Evals />;
    case "gameday":
      return <GameDay />;
    case "kpis":
      return <KPIs />;
    case "reports":
      return <Reports />;
    default: {
      const n = NAV.find((x) => x.key === section);
      return (
        <Card title={n?.label ?? "Not found"}>
          <p className="text-sm text-ink-3">
            {n?.day ? `Built on Day ${n.day}. Until then: tools/mc.py and the terminal.` : `No screen called “${section}”.`}
          </p>
        </Card>
      );
    }
  }
}

function AuditPage() {
  const { data } = useAudit(200);
  return <Card title="Audit log — every action attempt and every AI tool call (tier 0), any entrance">{data ? <AuditTable rows={data} /> : <Skeleton className="h-40" />}</Card>;
}

function PaletteHint() {
  const { open } = usePalette();
  return (
    <button onClick={open} className="rounded-md border border-line px-2 py-1 text-xs text-ink-3 hover:text-ink" title="Command palette">
      Ctrl K
    </button>
  );
}
