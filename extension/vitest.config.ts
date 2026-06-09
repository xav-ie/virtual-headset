import { defineConfig } from "vitest/config";

// jsdom gives the site adapters a DOM to read against fixture markup.
export default defineConfig({
  test: {
    environment: "jsdom",
    include: ["test/**/*.test.ts"],
  },
});
