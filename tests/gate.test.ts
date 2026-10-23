import { describe, expect, it, vi } from "vitest";
import { gateRequest, type ToolSpec } from "../src/security/gate";

const specs: ToolSpec[] = [
  { name: "listTabs", kind: "read", description: "list" },
  { name: "openTab", kind: "write", description: "open" },
];
const lookup = (name: string) => specs.find((s) => s.name === name);

describe("consent gate", () => {
  it("allows read tools without consulting consent", async () => {
    const consent = vi.fn().mockResolvedValue(true);
    const result = await gateRequest({ name: "listTabs", args: {} }, lookup, consent);
    expect(result).toEqual({ verdict: "allow", reason: "read-allowed" });
    expect(consent).not.toHaveBeenCalled();
  });

  it("allows a write when the user consents, passing the full request", async () => {
    const consent = vi.fn().mockResolvedValue(true);
    const request = { name: "openTab", args: { url: "https://x.test" } };
    const result = await gateRequest(request, lookup, consent);
    expect(result).toEqual({ verdict: "allow", reason: "consent-granted" });
    expect(consent).toHaveBeenCalledWith(request);
  });

  it("refuses a write when consent is denied", async () => {
    const consent = vi.fn().mockResolvedValue(false);
    const result = await gateRequest({ name: "openTab", args: {} }, lookup, consent);
    expect(result).toEqual({ verdict: "refuse", reason: "consent-denied" });
  });

  it("refuses unknown tools outright without prompting", async () => {
    const consent = vi.fn().mockResolvedValue(true);
    const result = await gateRequest({ name: "stealSecrets", args: {} }, lookup, consent);
    expect(result).toEqual({ verdict: "refuse", reason: "unknown-tool" });
    expect(consent).not.toHaveBeenCalled();
  });
});
