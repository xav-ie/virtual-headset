import { defineConfig } from "vitest/config";

// Pure logic only (no GTK), so the default node environment is fine.
export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
  },
});
