// A question handed to the Copilot page from elsewhere (the palette's /ask), consumed once.
let draft: string | null = null;
export const setCopilotDraft = (q: string) => { draft = q; };
export const takeCopilotDraft = (): string | null => { const d = draft; draft = null; return d; };
