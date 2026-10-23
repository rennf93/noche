import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["tests/**/*.test.ts"],
    // Playwright specs (tests/e2e/*.spec.ts) run under `npm run e2e` against a
    // real chromium, never under vitest. The include glob already skips them;
    // the explicit exclude keeps that true if one is ever renamed.
    exclude: [
      "**/node_modules/**",
      "**/dist/**",
      "**/.{idea,git,cache,output,temp}/**",
      "tests/e2e/**",
    ],
    // Loopback fixture-server tests finish in well under a second on an idle
    // machine, but vitest's 5s default clips them when the box is under heavy
    // parallel load. The timeout is a resource ceiling, not part of any spec.
    testTimeout: 30_000,
    hookTimeout: 30_000,
    coverage: {
      include: [
        "src/providers/**",
        "src/context/**",
        "src/settings/**",
        "src/security/**",
        "src/chat/**",
        "src/history/**",
        "src/skills/**",
        "src/ui/**",
        "src/agent/**",
      ],
      thresholds: {
        lines: 100,
        branches: 100,
        functions: 100,
        statements: 100,
      },
    },
  },
});
