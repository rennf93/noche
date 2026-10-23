import { describe, expect, it } from "vitest";
import { actionClass, actionKey, agentActionSchema } from "../src/agent/actions";

describe("agent action schema", () => {
  it("accepts every action shape the planner may emit", () => {
    const accepted = [
      { kind: "click", selector: "#buy" },
      { kind: "type", selector: "#email", text: "a@b.test" },
      { kind: "type", selector: "#note", text: "" },
      { kind: "scroll", direction: "down", amount: 600 },
      { kind: "scroll", direction: "up", amount: 1 },
      { kind: "extract", selector: "main h1" },
      { kind: "extract" },
      { kind: "extract", selector: undefined },
    ];
    for (const action of accepted) {
      expect(agentActionSchema.safeParse(action).success, JSON.stringify(action)).toBe(true);
    }
  });

  it("rejects malformed actions", () => {
    const rejected: unknown[] = [
      { kind: "press", selector: "#x" },
      { selector: "#x" },
      { kind: "click", selector: "" },
      { kind: "click" },
      { kind: "type", selector: "#x" },
      { kind: "type", selector: "", text: "hi" },
      { kind: "scroll", direction: "sideways", amount: 10 },
      { kind: "scroll", direction: "down", amount: 0 },
      { kind: "scroll", direction: "down", amount: -5 },
      { kind: "scroll", direction: "down", amount: 1.5 },
      { kind: "extract", selector: "" },
      { kind: "click", selector: "#x", extra: true },
      "click #x",
    ];
    for (const bad of rejected) {
      expect(agentActionSchema.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    }
  });
});

describe("actionClass", () => {
  it("classifies click and type as writes, scroll and extract as reads", () => {
    expect(actionClass({ kind: "click", selector: "#a" })).toBe("write");
    expect(actionClass({ kind: "type", selector: "#a", text: "x" })).toBe("write");
    expect(actionClass({ kind: "scroll", direction: "down", amount: 600 })).toBe("read");
    expect(actionClass({ kind: "extract" })).toBe("read");
  });
});

describe("actionKey", () => {
  it("is stable regardless of property insertion order", () => {
    const planned = { selector: "#buy", kind: "click" } as { kind: "click"; selector: string };
    expect(actionKey(planned)).toBe(actionKey({ kind: "click", selector: "#buy" }));
  });

  it("distinguishes every field of every kind, and is collision-free on separators", () => {
    const keys = [
      actionKey({ kind: "click", selector: "#a" }),
      actionKey({ kind: "click", selector: "#b" }),
      actionKey({ kind: "type", selector: "#a", text: "b:c" }),
      actionKey({ kind: "type", selector: "a:b", text: "c" }),
      actionKey({ kind: "type", selector: "#a", text: "other" }),
      actionKey({ kind: "scroll", direction: "up", amount: 100 }),
      actionKey({ kind: "scroll", direction: "down", amount: 100 }),
      actionKey({ kind: "scroll", direction: "down", amount: 200 }),
      actionKey({ kind: "extract" }),
      actionKey({ kind: "extract", selector: "main" }),
    ];
    expect(new Set(keys).size).toBe(keys.length);
    // Explicit undefined and an absent key are the same extract action.
    expect(actionKey({ kind: "extract", selector: undefined })).toBe(actionKey({ kind: "extract" }));
  });
});
