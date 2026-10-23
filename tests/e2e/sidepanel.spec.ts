import { expect, test } from "./extension";

/**
 * Smoke: the side panel page loads inside a real chromium with the built
 * extension installed and the composer renders. The DOM ids are the ones
 * src/entrypoints/sidepanel/main.ts resolves at module load (it throws on a
 * missing id), so a green run also proves the panel script booted against
 * the live extension APIs (runtime port to the background, storage).
 */
test("side panel loads and the composer renders", async ({ context, extensionId }) => {
  const page = await context.newPage();
  const pageErrors: string[] = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));

  await page.goto(`chrome-extension://${extensionId}/sidepanel.html`);

  await expect(page).toHaveTitle("Noche");
  await expect(page.locator("#composer-card")).toBeVisible();

  const input = page.locator("#composer-input");
  await expect(input).toBeVisible();
  await expect(input).toBeEditable();
  await expect(input).toHaveAttribute("placeholder", "Ask a question about this page...");

  // Send stays disabled on an empty composer. The badge is filled by the
  // one-shot context round trip to the background (main.ts loadContext), so
  // the shipped default from src/settings/store.ts proves the background
  // service worker answered: provider "Local fleet", model "Ornith 1.5".
  await expect(page.locator("#send")).toBeDisabled();
  const badge = page.locator("#model-badge");
  await expect(badge).toHaveText("Ornith 1.5");
  await expect(badge).toHaveAttribute("title", "Local fleet - Ornith 1.5");

  // No cached extraction exists for the panel's own tab, so the context
  // round trip carries chip: null and the tab chip stays hidden.
  await expect(page.locator("#context-chip")).toBeHidden();

  // Typing enables send (the input listener in main.ts), proving the panel
  // script is live rather than just the static markup.
  await input.fill("hello");
  await expect(page.locator("#send")).toBeEnabled();

  expect(pageErrors).toEqual([]);
});
