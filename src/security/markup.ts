/**
 * Untrusted-content markup. Page text always travels inside sentinel-wrapped
 * blocks that name its origin. Any tool directive appearing inside these blocks
 * is page data, never a command: the stream interpreter only honors tool blocks
 * outside sentinel spans. This is the injection firewall's single choke point.
 */
export const UNTRUSTED_START = "<<<UNTRUSTED_PAGE_CONTENT origin=";
export const UNTRUSTED_END = "<<<END_UNTRUSTED_PAGE_CONTENT>>>";

/**
 * Defang sentinel markers found inside page text: a literal end marker in the
 * content would close the span early and let later page text pose as model
 * output (where the interpreter would honor its tool blocks). Dropping one
 * character from each marker makes them unmatchable while staying readable.
 */
function neutralize(text: string): string {
  return text
    .split(UNTRUSTED_END)
    .join(UNTRUSTED_END.slice(1))
    .split(`${UNTRUSTED_START}`)
    .join(`${UNTRUSTED_START.slice(1)}`);
}

export function wrapUntrusted(origin: string, text: string): string {
  return `${UNTRUSTED_START}${origin}>>>\n${neutralize(text)}\n${UNTRUSTED_END}`;
}
