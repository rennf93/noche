/**
 * Pure DOM helpers for the chat rail, split out of the entrypoint so the
 * fiddly parts (streaming suffix appends, autoscroll stickiness, chip glyphs)
 * are unit-tested under jsdom. No state lives here; callers own it.
 */

export interface AppendedChunk {
  span: HTMLSpanElement;
}

/**
 * Append only the new suffix of growing streamed text, as a span the caller
 * fades in on its next animation frame (CSS transition, no JS animation). A
 * shrink (new chat reset, trimmed text) replaces the content instead.
 * Returns the appended span, or null when nothing grew.
 */
export function appendTextDelta(
  container: HTMLElement,
  fullText: string,
  renderedLength: number,
): AppendedChunk | null {
  if (fullText.length < renderedLength) {
    container.textContent = fullText;
    return null;
  }
  if (fullText.length === renderedLength) return null;
  const doc = container.ownerDocument;
  const span = doc.createElement("span");
  span.className = "chunk chunk-enter";
  span.textContent = fullText.slice(renderedLength);
  container.appendChild(span);
  return { span };
}

/** True while the scroller is close enough to the bottom to pin on append. */
export function shouldStickToBottom(el: HTMLElement, slackPx = 48): boolean {
  return el.scrollTop + el.clientHeight >= el.scrollHeight - slackPx;
}

/**
 * The single glyph on a context chip's favicon tile: the first character of
 * the host, www-stripped and uppercased. Anything non-alphanumeric degrades
 * to a neutral star.
 */
export function chipGlyph(origin: string): string {
  const host = origin.replace(/^[a-z]+:\/\//, "").replace(/^www\./, "");
  const first = (host[0] ?? "").toUpperCase();
  return /[A-Z0-9]/.test(first) ? first : "*";
}
