/**
 * Pure model-selection helpers, deliberately zod-free: UI surfaces bind to
 * settings-derived data without pulling the schema runtime into their bundle
 * (src/providers/schema.ts keeps the zod schemas and delegates here).
 */

export interface ModelLike {
  id: string;
  label?: string;
  default?: boolean;
}

/**
 * The model a catalog binds by default: the one flagged default, else the
 * first. An empty catalog is a config bug and throws, never a guess.
 */
export function defaultModelOf<M extends ModelLike>(models: readonly M[]): M {
  const flagged = models.find((m) => m.default);
  if (flagged) return flagged;
  const first = models[0];
  if (!first) throw new Error("provider has no models");
  return first;
}
