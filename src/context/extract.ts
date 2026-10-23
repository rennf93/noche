import { Readability } from "@mozilla/readability";
import { estimateTokens } from "./tokens";

/**
 * A page's clean extraction. Runs in the content script where the real page DOM
 * lives (so no fake-DOM dependency ships in the bundle). Origin travels with the
 * text: every consumer labels this chunk as untrusted content from this origin.
 */
export interface ExtractedPage {
  origin: string;
  url: string;
  title: string;
  text: string;
  tokens: number;
}

/** Null-safe body text: every degenerate body shape yields "" (unit-tested directly). */
export function bodyTextOf(doc: Document): string {
  const body = doc.body;
  if (body === null || body === undefined) return "";
  return body.textContent ?? "";
}

/** Extract readable text; falls back to body text when Readability finds no article. */
export function extractPage(doc: Document): ExtractedPage {
  const url = doc.documentURI;
  const origin = new URL(url).origin;
  const docTitle = doc.title || origin;
  let parsed: ReturnType<Readability["parse"]> = null;
  try {
    // Hostile or degenerate DOMs (no documentElement, cyclic trees) can make
    // Readability throw; a browser context must survive every page it meets.
    parsed = new Readability(doc).parse();
  } catch {
    parsed = null;
  }
  if (parsed === null) {
    const fallback = bodyTextOf(doc).trim();
    return { origin, url, title: docTitle, text: fallback, tokens: estimateTokens(fallback) };
  }
  // Readability's char-count guarantee: a non-null parse always carries text.
  const text = parsed.textContent as string;
  return {
    origin,
    url,
    title: (parsed.title as string | null) || docTitle,
    text,
    tokens: estimateTokens(text),
  };
}
