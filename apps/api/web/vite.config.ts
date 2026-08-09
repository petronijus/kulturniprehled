/// <reference types="vitest/config" />
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// Served same-origin by FastAPI at /app; hashed assets must resolve there.
// In dev, /v1 is proxied to the local compose stack (API_HOST_PORT=18000).
export default defineConfig({
  base: "/app/",
  plugins: [react()],
  server: {
    proxy: {
      "/v1": {
        target: "http://localhost:18000",
        changeOrigin: true,
      },
    },
  },
  test: {
    environment: "node",
    include: ["src/**/*.test.ts"],
  },
});
