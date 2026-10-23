/** Rough token estimate (chars/4 heuristic); precision is not worth bytes. */
export function estimateTokens(text: string): number {
  return Math.ceil(text.length / 4);
}
