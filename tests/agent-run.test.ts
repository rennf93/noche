import { describe, expect, it, vi } from "vitest";
import type { AgentAction } from "../src/agent/actions";
import type { PageOutline } from "../src/agent/ground";
import {
  runAgent,
  type AgentEvent,
  type AgentRunInput,
  type AgentRunResult,
  type PageExecutor,
  type Planner,
} from "../src/agent/run";

const outline: PageOutline = {
  origin: "https://shop.test",
  elements: [{ role: "button", name: "Buy", selector: "#buy" }],
};

function planOf(...actions: AgentAction[]): Planner {
  return { plan: async () => actions };
}

function stubExecutor(): PageExecutor & { calls: string[] } {
  const calls: string[] = [];
  return {
    calls,
    click: async (selector) => {
      calls.push(`click:${selector}`);
    },
    type: async (selector, text) => {
      calls.push(`type:${selector}:${text}`);
    },
    scroll: async (direction, amount) => {
      calls.push(`scroll:${direction}:${amount}`);
    },
    extract: async (selector) => {
      calls.push(`extract:${selector ?? "page"}`);
      return `text-of:${selector ?? "page"}`;
    },
  };
}

async function collect(
  input: Omit<AgentRunInput, "onEvent">,
): Promise<{ events: AgentEvent[]; result: AgentRunResult }> {
  const events: AgentEvent[] = [];
  const result = await runAgent({ ...input, onEvent: (event) => events.push(event) });
  return { events, result };
}

function stopEvent(events: AgentEvent[]): AgentEvent & { type: "stop" } {
  const stops = events.filter((event) => event.type === "stop");
  expect(stops).toHaveLength(1);
  return stops[0] as AgentEvent & { type: "stop" };
}

const scroll: AgentAction = { kind: "scroll", direction: "down", amount: 600 };

describe("runAgent", () => {
  it("executes a mixed plan: reads run freely, each write prompts once", async () => {
    const executor = stubExecutor();
    const consent = vi.fn(async () => true);
    const { events, result } = await collect({
      goal: "buy the thing",
      outline,
      planner: planOf(
        scroll,
        { kind: "extract" },
        { kind: "click", selector: "#buy" },
        { kind: "click", selector: "#buy" },
        { kind: "type", selector: "#email", text: "a@b.test" },
        { kind: "extract", selector: "main h1" },
      ),
      executor,
      consent,
    });
    expect(result).toEqual({
      reason: "completed",
      stepsExecuted: 6,
      planLength: 6,
      extracts: ["text-of:page", "text-of:main h1"],
    });
    expect(executor.calls).toEqual([
      "scroll:down:600",
      "extract:page",
      "click:#buy",
      "click:#buy",
      "type:#email:a@b.test",
      "extract:main h1",
    ]);
    // One consult per distinct write action (click repeated once, type once).
    expect(consent).toHaveBeenCalledTimes(2);
    expect(events.map((event) => event.type)).toEqual([
      "plan",
      "step",
      "step",
      "consent-request",
      "step",
      "step",
      "consent-request",
      "step",
      "step",
      "stop",
    ]);
    expect(events[0]).toMatchObject({ type: "plan" });
    expect(stopEvent(events)).toMatchObject({ reason: "completed", stepsExecuted: 6 });
  });

  it("emits extract text on the step event but leaves it off other kinds", async () => {
    const { events } = await collect({
      goal: "read",
      outline,
      planner: planOf(scroll, { kind: "extract", selector: "h1" }),
      executor: stubExecutor(),
      consent: vi.fn(async () => true),
    });
    const steps = events.filter((event) => event.type === "step") as Extract<
      AgentEvent,
      { type: "step" }
    >[];
    expect(steps[0]).toMatchObject({ index: 1, action: scroll });
    expect("text" in steps[0] && steps[0].text).toBeUndefined();
    expect(steps[1]).toMatchObject({ index: 2, action: { kind: "extract", selector: "h1" }, text: "text-of:h1" });
  });

  it("stops the run when consent is denied and never touches later steps", async () => {
    const executor = stubExecutor();
    const consent = vi.fn(async () => false);
    const { events, result } = await collect({
      goal: "buy",
      outline,
      planner: planOf(scroll, { kind: "click", selector: "#buy" }, { kind: "click", selector: "#cancel" }),
      executor,
      consent,
    });
    expect(result).toEqual({
      reason: "consent-denied",
      stepsExecuted: 1,
      planLength: 3,
      extracts: [],
    });
    expect(executor.calls).toEqual(["scroll:down:600"]);
    expect(consent).toHaveBeenCalledTimes(1);
    expect(events.map((event) => event.type)).toEqual(["plan", "step", "consent-request", "stop"]);
  });

  it("caps execution at 8 steps when the plan is longer", async () => {
    const executor = stubExecutor();
    const consent = vi.fn(async () => true);
    const nine = Array.from({ length: 9 }, () => scroll);
    const { result } = await collect({
      goal: "scroll a lot",
      outline,
      planner: planOf(...nine),
      executor,
      consent,
    });
    expect(result.reason).toBe("step-limit");
    expect(result.stepsExecuted).toBe(8);
    expect(executor.calls).toHaveLength(8);
    expect(consent).not.toHaveBeenCalled();
  });

  it("completes a plan of exactly 8 steps", async () => {
    const executor = stubExecutor();
    const eight = Array.from({ length: 8 }, () => scroll);
    const { result } = await collect({
      goal: "eight scrolls",
      outline,
      planner: planOf(...eight),
      executor,
      consent: vi.fn(async () => true),
    });
    expect(result).toEqual({
      reason: "completed",
      stepsExecuted: 8,
      planLength: 8,
      extracts: [],
    });
  });

  it("completes an empty plan without executing anything", async () => {
    const executor = stubExecutor();
    const { events, result } = await collect({
      goal: "nothing to do",
      outline,
      planner: planOf(),
      executor,
      consent: vi.fn(async () => true),
    });
    expect(result).toEqual({ reason: "completed", stepsExecuted: 0, planLength: 0, extracts: [] });
    expect(executor.calls).toEqual([]);
    expect(events.map((event) => event.type)).toEqual(["plan", "stop"]);
  });

  it("refuses to run a plan with a malformed step, before executing anything", async () => {
    const executor = stubExecutor();
    const { events, result } = await collect({
      goal: "typo in the plan",
      outline,
      planner: planOf(scroll, { kind: "click", selector: "" } as unknown as AgentAction),
      executor,
      consent: vi.fn(async () => true),
    });
    expect(result.reason).toBe("invalid-step");
    expect(result.stepsExecuted).toBe(0);
    expect(result.message).toContain("invalid action at step 2");
    expect(executor.calls).toEqual([]);
    expect(events.map((event) => event.type)).toEqual(["stop"]);
  });

  it("refuses a non-array plan", async () => {
    const badPlanner: Planner = {
      plan: async () => "click the button" as unknown as AgentAction[],
    };
    const { result } = await collect({
      goal: "gibberish planner",
      outline,
      planner: badPlanner,
      executor: stubExecutor(),
      consent: vi.fn(async () => true),
    });
    expect(result).toMatchObject({ reason: "invalid-step", message: "planner returned a non-array plan" });
  });

  it("surfaces a planner failure as a failed run", async () => {
    const exploding: Planner = {
      plan: async () => {
        throw new Error("planner down");
      },
    };
    const { events, result } = await collect({
      goal: "any",
      outline,
      planner: exploding,
      executor: stubExecutor(),
      consent: vi.fn(async () => true),
    });
    expect(result).toEqual({
      reason: "failed",
      stepsExecuted: 0,
      planLength: 0,
      extracts: [],
      message: "planner down",
    });
    expect(events.map((event) => event.type)).toEqual(["stop"]);
  });

  it("stringifies non-Error planner failures", async () => {
    const exploding: Planner = {
      plan: async () => {
        throw "planner string failure";
      },
    };
    const { result } = await collect({
      goal: "any",
      outline,
      planner: exploding,
      executor: stubExecutor(),
      consent: vi.fn(async () => true),
    });
    expect(result).toMatchObject({ reason: "failed", message: "planner string failure" });
  });

  it("stops with failed when the executor throws, keeping earlier results", async () => {
    const executor = stubExecutor();
    executor.click = async () => {
      throw new Error("selector not found: #buy");
    };
    const { result } = await collect({
      goal: "buy",
      outline,
      planner: planOf({ kind: "extract" }, { kind: "click", selector: "#buy" }, scroll),
      executor,
      consent: vi.fn(async () => true),
    });
    expect(result).toEqual({
      reason: "failed",
      stepsExecuted: 1,
      planLength: 3,
      extracts: ["text-of:page"],
      message: "selector not found: #buy",
    });
  });

  it("stringifies non-Error executor failures", async () => {
    const executor = stubExecutor();
    executor.scroll = async () => {
      throw "not an error object";
    };
    const { result } = await collect({
      goal: "scroll",
      outline,
      planner: planOf(scroll),
      executor,
      consent: vi.fn(async () => true),
    });
    expect(result).toMatchObject({ reason: "failed", message: "not an error object" });
  });

  it("works without an onEvent callback", async () => {
    const executor = stubExecutor();
    const result = await runAgent({
      goal: "quiet run",
      outline,
      planner: planOf(scroll),
      executor,
      consent: vi.fn(async () => true),
    });
    expect(result.reason).toBe("completed");
    expect(executor.calls).toEqual(["scroll:down:600"]);
  });

  it("the runner's consent gate fails closed when the callback throws", async () => {
    const executor = stubExecutor();
    const { result } = await collect({
      goal: "buy",
      outline,
      planner: planOf({ kind: "click", selector: "#buy" }),
      executor,
      consent: async () => {
        throw new Error("prompt ui crashed");
      },
    });
    expect(result).toMatchObject({ reason: "consent-denied", stepsExecuted: 0 });
    expect(executor.calls).toEqual([]);
  });
});
