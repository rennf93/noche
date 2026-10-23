import { z } from "zod";

/**
 * The four page actions an agent run may take. click and type mutate the page
 * (they can submit forms, trigger navigations, change state), so they are
 * writes and sit behind the consent gate; scroll and extract only observe, so
 * they are reads and never prompt.
 */
export type AgentAction =
  | { kind: "click"; selector: string }
  | { kind: "type"; selector: string; text: string }
  | { kind: "scroll"; direction: "up" | "down"; amount: number }
  | { kind: "extract"; selector?: string };

export type AgentActionKind = AgentAction["kind"];
export type ScrollDirection = "up" | "down";

/** Same read/write split as the chat tool registry (src/security/gate.ts). */
export type ActionKind = "read" | "write";

const clickAction = z
  .object({ kind: z.literal("click"), selector: z.string().min(1) })
  .strict();
const typeAction = z
  .object({ kind: z.literal("type"), selector: z.string().min(1), text: z.string() })
  .strict();
const scrollAction = z
  .object({
    kind: z.literal("scroll"),
    direction: z.enum(["up", "down"]),
    amount: z.number().int().positive(),
  })
  .strict();
const extractAction = z
  .object({ kind: z.literal("extract"), selector: z.string().min(1).optional() })
  .strict();

/**
 * Planner output is model-supplied and untrusted, so every action is validated
 * against this schema before anything runs (same rule as chat tool args).
 * Strict objects make unknown keys an error; an empty selector is rejected
 * because querySelector("") always throws.
 */
export const agentActionSchema = z.discriminatedUnion("kind", [
  clickAction,
  typeAction,
  scrollAction,
  extractAction,
]);

/** Writes are exactly the mutating kinds; reads pass without prompting. */
export function actionClass(action: AgentAction): ActionKind {
  return action.kind === "click" || action.kind === "type" ? "write" : "read";
}

/**
 * Canonical identity of an action, used to memoize consent inside one run:
 * approving a write once covers later repeats of the same write in that run.
 * Built field-by-field in fixed key order so two structurally identical
 * actions always serialize to the same string (plain JSON.stringify of the
 * planner's object would depend on key insertion order).
 */
export function actionKey(action: AgentAction): string {
  if (action.kind === "click") {
    return JSON.stringify({ kind: action.kind, selector: action.selector });
  }
  if (action.kind === "type") {
    return JSON.stringify({ kind: action.kind, selector: action.selector, text: action.text });
  }
  if (action.kind === "scroll") {
    return JSON.stringify({ kind: action.kind, direction: action.direction, amount: action.amount });
  }
  return JSON.stringify({ kind: action.kind, selector: action.selector ?? null });
}
