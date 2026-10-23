import {
  agentActionSchema,
  type AgentAction,
  type ScrollDirection,
} from "./actions";
import { createRunConsent, type ConsentProbe } from "./consent";
import type { PageOutline } from "./ground";

/** Hard ceiling on executed steps per run; a longer plan stops at the cap. */
export const MAX_AGENT_STEPS = 8;

/** Everything a planner sees: what the user asked for and the page as serialized. */
export interface PlanInput {
  goal: string;
  outline: PageOutline;
}

/**
 * The planning half of the agent: turns a user goal into a bounded action
 * sequence. Injected into runAgent so tests script plans directly; the real
 * implementation is model-backed and lives behind this interface. A planner
 * works in role/name space and uses groundElement to fill selectors; it never
 * decides consent or step limits, the runner owns those.
 */
export interface Planner {
  plan(input: PlanInput): Promise<AgentAction[]>;
}

/**
 * The execution half of the agent, implemented by chrome glue in the
 * entrypoint layer (like ToolAdapters in src/chat/tools.ts). Tests inject
 * recording stubs; no browser API is touched here.
 */
export interface PageExecutor {
  click(selector: string): Promise<void>;
  type(selector: string, text: string): Promise<void>;
  scroll(direction: ScrollDirection, amount: number): Promise<void>;
  /** Page text, or the text of the element matching selector when given. */
  extract(selector: string | undefined): Promise<string>;
}

/** Why a run stopped. Every run stops exactly once with exactly one reason. */
export type AgentStopReason =
  | "completed"
  | "step-limit"
  | "consent-denied"
  | "invalid-step"
  | "failed";

export type AgentEvent =
  | { type: "plan"; actions: AgentAction[] }
  | { type: "consent-request"; action: AgentAction }
  | { type: "step"; index: number; action: AgentAction; text?: string }
  | { type: "stop"; reason: AgentStopReason; stepsExecuted: number; message?: string };

export interface AgentRunResult {
  reason: AgentStopReason;
  stepsExecuted: number;
  /** Validated plan length; 0 when planning or validation failed. */
  planLength: number;
  /** Text captured by extract steps, in execution order. */
  extracts: string[];
  /** Set for "failed" (planner or executor error) and "invalid-step". */
  message?: string;
}

export interface AgentRunInput {
  goal: string;
  outline: PageOutline;
  planner: Planner;
  executor: PageExecutor;
  /** Consulted once per distinct write action per run (grants are memoized). */
  consent: ConsentProbe;
  onEvent?: (event: AgentEvent) => void;
}

/**
 * One agent run: plan, validate the whole plan up front (a malformed step
 * aborts before anything executes), then execute step by step under the
 * consent gate. Reads (scroll, extract) run freely; writes (click, type)
 * prompt on first appearance and reuse that grant for repeats within the run.
 * Stop conditions: plan exhausted ("completed"), the 8-step cap ("step-limit"),
 * a refused write ("consent-denied", terminal for the run), a malformed plan
 * ("invalid-step"), and any planner or executor error ("failed"). Every path
 * ends in exactly one stop event and never rejects.
 */
export async function runAgent(input: AgentRunInput): Promise<AgentRunResult> {
  const emit = (event: AgentEvent): void => {
    if (input.onEvent !== undefined) input.onEvent(event);
  };
  const stop = (
    reason: AgentStopReason,
    stepsExecuted: number,
    planLength: number,
    extracts: string[],
    message?: string,
  ): AgentRunResult => {
    const result: AgentRunResult = { reason, stepsExecuted, planLength, extracts };
    if (message !== undefined) result.message = message;
    emit({ type: "stop", reason, stepsExecuted, message });
    return result;
  };

  let planned: unknown;
  try {
    planned = await input.planner.plan({ goal: input.goal, outline: input.outline });
  } catch (err) {
    return stop("failed", 0, 0, [], err instanceof Error ? err.message : String(err));
  }
  if (!Array.isArray(planned)) {
    return stop("invalid-step", 0, 0, [], "planner returned a non-array plan");
  }
  const plan: AgentAction[] = [];
  for (let i = 0; i < planned.length; i++) {
    const parsed = agentActionSchema.safeParse(planned[i]);
    if (!parsed.success) {
      return stop("invalid-step", 0, 0, [], `invalid action at step ${i + 1}: ${parsed.error.message}`);
    }
    plan.push(parsed.data);
  }
  emit({ type: "plan", actions: plan });

  const gate = createRunConsent(async (action: AgentAction) => {
    emit({ type: "consent-request", action });
    return input.consent(action);
  });
  const extracts: string[] = [];
  let executed = 0;
  for (let i = 0; i < plan.length; i++) {
    if (executed >= MAX_AGENT_STEPS) return stop("step-limit", executed, plan.length, extracts);
    const action = plan[i];
    const allowed = await gate.check(action);
    if (!allowed) return stop("consent-denied", executed, plan.length, extracts);
    try {
      let text: string | undefined;
      if (action.kind === "click") {
        await input.executor.click(action.selector);
      } else if (action.kind === "type") {
        await input.executor.type(action.selector, action.text);
      } else if (action.kind === "scroll") {
        await input.executor.scroll(action.direction, action.amount);
      } else {
        text = await input.executor.extract(action.selector);
        extracts.push(text);
      }
      executed++;
      emit({ type: "step", index: i + 1, action, text });
    } catch (err) {
      return stop("failed", executed, plan.length, extracts, err instanceof Error ? err.message : String(err));
    }
  }
  return stop("completed", executed, plan.length, extracts);
}
