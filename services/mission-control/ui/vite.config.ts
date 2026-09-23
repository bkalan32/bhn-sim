// Mission Control UI — built to static files that FastAPI serves from `/` (one container ships
// both, PDF stack section). `npm run dev` proxies /api to a port-forwarded mission-control.
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  build: { outDir: "dist", sourcemap: false, chunkSizeWarningLimit: 900 },
  server: { proxy: { "/api": "http://localhost:8040" } },
});
