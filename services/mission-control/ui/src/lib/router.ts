// A hash router in twenty lines. `#/incidents/INC-1790194952-ddb1` — the server only ever serves
// `/`, so a deep link or a reload can never 404, and there is no route table to keep in sync
// with FastAPI. Six screens do not need a router library.
import { useEffect, useState } from "react";

export function currentPath(): string[] {
  const h = window.location.hash.replace(/^#\/?/, "");
  return h ? h.split("/").map(decodeURIComponent) : [];
}

export function useRoute(): string[] {
  const [path, setPath] = useState(currentPath);
  useEffect(() => {
    const on = () => setPath(currentPath());
    window.addEventListener("hashchange", on);
    return () => window.removeEventListener("hashchange", on);
  }, []);
  return path;
}

export const href = (...parts: string[]) => "#/" + parts.map(encodeURIComponent).join("/");
