import { describe, expect, it, vi } from "vitest";
import { createRunConsent } from "../src/agent/consent";
import type { AgentAction } from "../src/agent/actions";

const clickBuy: AgentAction = { kind: "click", selector: "#buy" };
const clickBuyAgain: AgentAction = { kind: "click", selector: "#buy" };
const clickCancel: AgentAction = { kind: "click", selector: "#cancel" };
const typeEmail: AgentAction = { kind: "type", selector: "#email", text: "a@b.test" };
const scrollDown: AgentAction = { kind: "scroll", direction: "down", amount: 600 };
const extract: AgentAction = { kind: "extract" };

describe("createRunConsent", () => {
  it("allows reads without ever consulting the consent callback", async () => {
    const consent = vi.fn(async () => true);
    const gate = createRunConsent(consent);
    expect(await gate.check(scrollDown)).toBe(true);
    expect(await gate.check(extract)).toBe(true);
    expect(consent).not.toHaveBeenCalled();
  });

  it("consults once for a write and reuses the grant for the same action in the run", async () => {
    const consent = vi.fn(async () => true);
    const gate = createRunConsent(consent);
    expect(await gate.check(clickBuy)).toBe(true);
    expect(await gate.check(clickBuyAgain)).toBe(true);
    expect(consent).toHaveBeenCalledTimes(1);
    expect(consent).toHaveBeenCalledWith(clickBuy);
  });

  it("prompts separately for a distinct write action", async () => {
    const consent = vi.fn(async () => true);
    const gate = createRunConsent(consent);
    await gate.check(clickBuy);
    await gate.check(clickCancel);
    await gate.check(typeEmail);
    expect(consent).toHaveBeenCalledTimes(3);
  });

  it("treats structurally identical actions as the same consent decision", async () => {
    const consent = vi.fn(async () => true);
    const gate = createRunConsent(consent);
    await gate.check({ kind: "click", selector: "#buy" });
    await gate.check({ selector: "#buy", kind: "click" } as AgentAction);
    expect(consent).toHaveBeenCalledTimes(1);
  });

  it("refuses a write when the user denies", async () => {
    const consent = vi.fn(async () => false);
    const gate = createRunConsent(consent);
    expect(await gate.check(clickBuy)).toBe(false);
    expect(consent).toHaveBeenCalledTimes(1);
  });

  it("fails closed when the consent callback throws", async () => {
    const consent = vi.fn(async () => {
      throw new Error("prompt ui crashed");
    });
    const gate = createRunConsent(consent);
    expect(await gate.check(clickBuy)).toBe(false);
  });
});
