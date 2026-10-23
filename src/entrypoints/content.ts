import { parseSurfaceMessage, type NocheMessage } from "../chat/protocol";
import { extractPage } from "../context/extract";

/**
 * Page context extraction and selection capture, requested on demand by the
 * background: readability-cleaned text for ask-about-page, the live selection
 * for ask-about-selection. Registered on all URLs but inert until messaged:
 * zero DOM work at page load. Wire shapes come from chat/protocol.ts; the
 * polyfill's async-listener form turns the returned value into the response,
 * so every message resolves and senders never hang.
 */
export default defineContentScript({
  matches: ["<all_urls>"],
  main() {
    browser.runtime.onMessage.addListener(async (message: unknown): Promise<unknown> => {
      const parsed = parseSurfaceMessage(message);
      if (parsed?.type === "noche:extract-page") {
        return extractPage(document);
      }
      if (parsed?.type === "noche:get-selection") {
        const text = document.getSelection()?.toString() ?? "";
        return { type: "noche:selection-response", text } satisfies NocheMessage;
      }
      return undefined;
    });
  },
});
