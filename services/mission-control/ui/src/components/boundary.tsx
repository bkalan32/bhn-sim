// A screen that throws must not take the whole console with it. Without a boundary React unmounts
// everything — header, approvals banner, nav — and leaves a blank page (CORRECTIONS-DAY23 B1). On
// game day 3 there is no terminal to recover from that. With it, only the broken screen is
// replaced by the error, and the banner (Approve/Decline) and the nav keep working.
import { Component, type ErrorInfo, type ReactNode } from "react";

type Props = { children: ReactNode; where: string };
type State = { error: Error | null };

export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error(`[mission-control] ${this.props.where} crashed:`, error, info.componentStack);
  }

  render() {
    const { error } = this.state;
    if (!error) return this.props.children;
    return (
      <div role="alert" className="rounded-lg border border-critical/70 bg-surface-2 p-4 text-sm">
        <h2 className="font-semibold text-ink">This screen hit a bug ({this.props.where})</h2>
        <p className="mt-1 text-ink-2">
          The rest of mission control still works — the approvals banner and the other screens are live.
          Nothing was executed by this error.
        </p>
        <pre className="mt-3 max-h-48 overflow-auto whitespace-pre-wrap rounded bg-surface-3 p-2 font-mono text-xs text-ink-2">
          {String(error.stack || error.message || error).slice(0, 2000)}
        </pre>
        <div className="mt-3 flex gap-3 text-xs">
          <button className="text-info hover:underline" onClick={() => this.setState({ error: null })}>Try this screen again</button>
          <a className="text-info hover:underline" href="#/">Overview</a>
          <button className="text-info hover:underline" onClick={() => window.location.reload()}>Reload the page</button>
        </div>
      </div>
    );
  }
}
