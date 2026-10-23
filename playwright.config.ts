import { defineConfig } from "@playwright/test";

/**
 * Playwright e2e for the built extension (.output/chrome-mv3, produced by
 * `wxt build`; `npm run e2e` builds first). Chrome extensions only load into a
 * persistent context, so the browser is launched by the fixture in
 * tests/e2e/extension.ts (chromium channel, new headless, --load-extension)
 * rather than by the default browser fixture here. Specs live under tests/e2e
 * as *.spec.ts and are excluded from vitest (vitest.config.ts).
 */
export default defineConfig({
  testDir: "tests/e2e",
  testMatch: "**/*.spec.ts",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  forbidOnly: true,
  timeout: 60_000,
  expect: { timeout: 10_000 },
  reporter: [["list"]],
  use: {
    channel: "chromium",
    headless: true,
    trace: "retain-on-failure",
  },
});
