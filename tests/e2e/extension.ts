import { test as base, chromium, type BrowserContext } from "@playwright/test";
import { existsSync } from "node:fs";
import { join } from "node:path";

/**
 * Fixtures that launch chromium with the built extension loaded. Extensions
 * require a persistent context (plain `browser.newContext()` cannot carry
 * --load-extension), and MV3 extensions only run under the `chromium`
 * channel in new headless mode, so the launch is explicit here instead of
 * coming from playwright.config.ts.
 */

export const extensionPath = join(process.cwd(), ".output", "chrome-mv3");

export const test = base.extend<{ context: BrowserContext; extensionId: string }>({
  context: async ({}, use) => {
    if (!existsSync(join(extensionPath, "manifest.json"))) {
      throw new Error(
        `built extension missing at ${extensionPath}; run \`npm run build\` first (or \`npm run e2e\`)`,
      );
    }
    const context = await chromium.launchPersistentContext("", {
      channel: "chromium",
      headless: true,
      args: [
        `--disable-extensions-except=${extensionPath}`,
        `--load-extension=${extensionPath}`,
      ],
    });
    await use(context);
    await context.close();
  },
  extensionId: async ({ context }, use) => {
    // The MV3 background is a service worker; its origin carries the id.
    let [worker] = context.serviceWorkers();
    if (!worker) worker = await context.waitForEvent("serviceworker");
    await use(new URL(worker.url()).host);
  },
});

export { expect } from "@playwright/test";
