import { actionClass, actionKey, type ActionKind, type AgentAction } from "./actions";

export type ConsentProbe = (action: AgentAction) => Promise<boolean>;

/**
 * Run-scoped consent gate for page actions, same rules as the chat tool gate
 * (src/security/gate.ts): reads are allowed without ever consulting the user,
 * writes wait for an explicit yes, and a failure inside the consent callback
 * counts as a refusal (fail closed).
 *
 * The run-scoped part is the "approved once per run" rule: a granted write is
 * memoized under its canonical action key, so the same write action appearing
 * again later in the same run does not prompt a second time. A distinct write
 * (different selector or text) is a new action and prompts on its own. Only
 * grants are memoized: a refusal is terminal for the whole run (runAgent stops
 * on it), so a cached refusal could never be consulted anyway.
 */
export interface RunConsent {
  /** True when the action may run: a read, a memoized grant, or a fresh grant. */
  check(action: AgentAction): Promise<boolean>;
}

export function createRunConsent(consent: ConsentProbe): RunConsent {
  const granted = new Map<string, true>();
  return {
    async check(action: AgentAction): Promise<boolean> {
      const kind: ActionKind = actionClass(action);
      if (kind === "read") return true;
      const key = actionKey(action);
      if (granted.has(key)) return true;
      let allowed: boolean;
      try {
        allowed = await consent(action);
      } catch {
        allowed = false;
      }
      if (!allowed) return false;
      granted.set(key, true);
      return true;
    },
  };
}
