import { describe, expect, it, vi } from "vitest";
import { executeTool, toolRegistry, type ToolAdapters } from "../src/chat/tools";

function stubAdapters(overrides: Partial<ToolAdapters> = {}): ToolAdapters & {
  calls: string[];
} {
  const calls: string[] = [];
  const push = (label: string) => {
    calls.push(label);
  };
  return {
    calls,
    listTabs: overrides.listTabs ?? (async () => (push("listTabs"), [{ id: 1, title: "T", url: "https://a.test" }])),
    openTab:
      overrides.openTab ??
      (async (url: string) => {
        push(`openTab:${url}`);
      }),
    closeTab:
      overrides.closeTab ??
      (async (tabId: number) => {
        push(`closeTab:${tabId}`);
      }),
    copyText:
      overrides.copyText ??
      (async (text: string) => {
        push(`copyText:${text}`);
      }),
  };
}

describe("tool registry", () => {
  it("declares read and write kinds", () => {
    expect(toolRegistry.listTabs?.spec.kind).toBe("read");
    expect(toolRegistry.openTab?.spec.kind).toBe("write");
    expect(toolRegistry.closeTab?.spec.kind).toBe("write");
    expect(toolRegistry.copyText?.spec.kind).toBe("write");
  });

  it("executes each tool through the injected adapter", async () => {
    const adapters = stubAdapters();
    await expect(executeTool(adapters, { name: "listTabs", args: {} })).resolves.toEqual({
      ok: true,
      value: [{ id: 1, title: "T", url: "https://a.test" }],
    });
    await expect(
      executeTool(adapters, { name: "openTab", args: { url: "https://x.test" } }),
    ).resolves.toEqual({ ok: true, value: undefined });
    await expect(
      executeTool(adapters, { name: "closeTab", args: { tabId: 7 } }),
    ).resolves.toEqual({ ok: true, value: undefined });
    await expect(
      executeTool(adapters, { name: "copyText", args: { text: "hi there" } }),
    ).resolves.toEqual({ ok: true, value: undefined });
    expect(adapters.calls).toEqual([
      "listTabs",
      "openTab:https://x.test",
      "closeTab:7",
      "copyText:hi there",
    ]);
  });

  it("refuses unknown tools", async () => {
    const result = await executeTool(stubAdapters(), { name: "exfiltrate", args: {} });
    expect(result).toEqual({ ok: false, error: "unknown tool: exfiltrate" });
  });

  it("rejects invalid args per schema", async () => {
    const adapters = stubAdapters();
    const cases = [
      { name: "listTabs", args: { extra: 1 } },
      { name: "openTab", args: {} },
      { name: "openTab", args: { url: "not a url" } },
      { name: "openTab", args: { url: "https://x.test", extra: 1 } },
      { name: "closeTab", args: { tabId: "7" } },
      { name: "closeTab", args: { tabId: 1.5 } },
      { name: "copyText", args: {} },
      { name: "copyText", args: { text: 5 } },
    ];
    for (const request of cases) {
      const result = await executeTool(adapters, request);
      expect(result.ok).toBe(false);
      expect(result.ok === false && result.error.startsWith("invalid args")).toBe(true);
    }
    expect(adapters.calls).toEqual([]);
  });

  it("captures adapter errors as results, Error or not", async () => {
    const boom = stubAdapters({
      openTab: async () => {
        throw new Error("tab crashed");
      },
    });
    const result = await executeTool(boom, { name: "openTab", args: { url: "https://x.test" } });
    expect(result).toEqual({ ok: false, error: "tab crashed" });
    const weird = stubAdapters({
      closeTab: async () => {
        throw "not an error object";
      },
    });
    const result2 = await executeTool(weird, { name: "closeTab", args: { tabId: 1 } });
    expect(result2).toEqual({ ok: false, error: "not an error object" });
  });
});
