export interface TabBudgetInput {
  tabId: number;
  /** Pre-estimated token count of the tab's cached extraction. */
  tokens: number;
  /** The focused tab gets priority when the window overflows. */
  active?: boolean;
}

export interface BudgetInput {
  /** The bound model's context window, from its provider config entry. */
  contextWindow: number;
  /** Tokens reserved for the model's reply. Default 1024. */
  reserveOutput?: number;
  tabs: TabBudgetInput[];
}

export interface TabAllocation {
  tabId: number;
  /** Tokens of this tab's text allowed into the prompt. */
  allowed: number;
  /** True when the tab fit entirely. */
  complete: boolean;
}

/**
 * Split a model's context window across candidate tabs. The active tab carries
 * weight 3, others 1; every tab fits fully when the window allows it, and the
 * per-tab floor is zero so empty tabs never steal budget.
 */
export function allocateBudget(input: BudgetInput): TabAllocation[] {
  const reserveOutput = input.reserveOutput ?? 1024;
  const systemReserve = 512;
  const usable = Math.max(0, input.contextWindow - reserveOutput - systemReserve);
  const candidates = input.tabs.filter((t) => t.tokens > 0);
  if (candidates.length === 0 || usable === 0) {
    return input.tabs.map((t) => ({ tabId: t.tabId, allowed: 0, complete: t.tokens === 0 }));
  }
  const total = candidates.reduce((sum, t) => sum + t.tokens, 0);
  if (total <= usable) {
    return input.tabs.map((t) => ({
      tabId: t.tabId,
      allowed: t.tokens,
      complete: true,
    }));
  }
  const weight = (t: TabBudgetInput): number => (t.active === true ? 3 : 1);
  const weightTotal = candidates.reduce((sum, t) => sum + weight(t), 0);
  return input.tabs.map((t) => {
    if (t.tokens === 0) return { tabId: t.tabId, allowed: 0, complete: true };
    const share = Math.floor((usable * weight(t)) / weightTotal);
    const allowed = Math.min(t.tokens, share);
    return { tabId: t.tabId, allowed, complete: allowed >= t.tokens };
  });
}
