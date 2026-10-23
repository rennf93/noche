import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { startFixtureServer, type FixtureServer } from "./fixture-server";
import { providerConfigSchema, type ProviderConfig } from "../src/providers/schema";
import { buildSystemPrompt, buildUserContent, runChat, type ChatEvent } from "../src/chat/orchestrator";
import type { ToolAdapters } from "../src/chat/tools";
import { UNTRUSTED_END, UNTRUSTED_START } from "../src/security/markup";

function stubAdapters(): ToolAdapters & {
  calls: string[];
  tabs: ToolAdapters["listTabs"];
} {
  const calls: string[] = [];
  const tabs = vi.fn(async () => {
    calls.push("listTabs");
    return [{ id: 1, title: "Docs", url: "https://docs.test" }];
  });
  return {
    calls,
    tabs,
    listTabs: tabs,
    openTab: async (url: string) => {
      calls.push(`openTab:${url}`);
    },
    closeTab: async (tabId: number) => {
      calls.push(`closeTab:${tabId}`);
    },
    copyText: async (text: string) => {
      calls.push(`copyText:${text}`);
    },
  };
}

function makeConfig(server: FixtureServer, contextWindow = 262144): ProviderConfig {
  return providerConfigSchema.parse({
    id: "fixture",
    label: "Fixture",
    baseUrl: server.url,
    wire: "openai-completions",
    auth: { type: "apiKey", headerStyle: "bearer" },
    models: [{ id: "north", label: "North", contextWindow }],
  });
}

function fence(name: string, args: unknown): string {
  return "```noche-tool\n" + JSON.stringify({ name, args }) + "\n```";
}

async function collect(input: Parameters<typeof runChat>[0]): Promise<ChatEvent[]> {
  const events: ChatEvent[] = [];
  await runChat({ ...input, onEvent: (event) => events.push(event) });
  return events;
}

const listTabsFence = fence("listTabs", {});

describe("runChat", () => {
  let server: FixtureServer;
  let config: ProviderConfig;
  let adapters: ReturnType<typeof stubAdapters>;
  const consent = vi.fn(async () => true);

  beforeEach(async () => {
    server = await startFixtureServer({ openaiScript: [[]] });
    config = makeConfig(server);
    adapters = stubAdapters();
    consent.mockClear().mockResolvedValue(true);
  });

  afterEach(async () => {
    await server.close();
  });

  it("streams a plain turn and emits text then done", async () => {
    await server.close();
    server = await startFixtureServer({ openaiScript: [["Hel", "lo"]] });
    const events = await collect({
      config: makeConfig(server),
      apiKey: "test-key",
      userMessage: "hi",
      adapters,
      consent,
      onEvent: () => undefined,
    });
    expect(events).toEqual([
      { type: "text", text: "Hel" },
      { type: "text", text: "lo" },
      { type: "done" },
    ]);
    expect(adapters.calls).toEqual([]);
  });

  it("builds a system prompt with the tool protocol and untrusted rules", async () => {
    const prompt = buildSystemPrompt();
    expect(prompt).toContain("```noche-tool");
    expect(prompt).toContain('"name":"toolName"');
    expect(prompt).toContain("- listTabs (read)");
    expect(prompt).toContain("- openTab (write)");
    expect(prompt).toContain(UNTRUSTED_START.slice(0, 20));
    expect(prompt).toContain(UNTRUSTED_END.slice(0, 20));
    expect(prompt).toContain("consent");
  });

  it("wraps tab context in sentinels after budgeting", async () => {
    const events = await collect({
      config,
      apiKey: "test-key",
      userMessage: "summarize",
      tabs: [
        { tabId: 1, origin: "https://a.test", text: "PAGE TEXT HERE", tokens: 4 },
        { tabId: 2, origin: "https://b.test", text: "", tokens: 0 },
      ],
      adapters,
      consent,
      onEvent: () => undefined,
    });
    expect(events[events.length - 1]?.type).toBe("done");
    const sent = JSON.parse(server.bodies[0] ?? "{}") as { messages: { role: string; content: string }[] };
    const user = sent.messages.find((m) => m.role === "user")?.content ?? "";
    expect(user.startsWith("summarize\n\n")).toBe(true);
    expect(user).toContain(`${UNTRUSTED_START}https://a.test>>>`);
    expect(user).toContain("PAGE TEXT HERE");
    expect(user).toContain(UNTRUSTED_END);
    expect(user).not.toContain("https://b.test");
    const system = sent.messages.find((m) => m.role === "system")?.content ?? "";
    expect(system).toContain("listTabs (read)");
    expect(system).toContain("consent");
  });

  it("trims tab text to the budgeted allowance and skips empty blocks", async () => {
    const ones = "A".repeat(16);
    const long = "B".repeat(160);
    await collect({
      config: makeConfig(server, 1024 + 512 + 16),
      apiKey: "test-key",
      userMessage: "q",
      tabs: [
        { tabId: 1, origin: "https://a.test", text: ones, tokens: 4 },
        { tabId: 2, origin: "https://b.test", text: long, tokens: 40 },
      ],
      adapters,
      consent,
      onEvent: () => undefined,
    });
    const user = (JSON.parse(server.bodies[0] ?? "{}") as { messages: { content: string }[] })
      .messages[1]?.content ?? "";
    expect(user).toContain(ones);
    expect(user).toContain("B".repeat(32));
    expect(user).not.toContain("B".repeat(33));
  });

  it("collapses to the bare question when the window allows nothing", async () => {
    await collect({
      config: makeConfig(server, 1088),
      apiKey: "test-key",
      userMessage: "q",
      tabs: [{ tabId: 1, origin: "https://a.test", text: "DATA", tokens: 1 }],
      adapters,
      consent,
      onEvent: () => undefined,
    });
    const sent = JSON.parse(server.bodies[0] ?? "{}") as { messages: { content: string }[] };
    expect(sent.messages[1]?.content).toBe("q");
  });

  it("runs read tools without consent and feeds results back", async () => {
    await server.close();
    server = await startFixtureServer({
      openaiScript: [
        ["Let me check. ```no", `che-tool\n${JSON.stringify({ name: "listTabs", args: {} })}`, "\n```"],
        ["Tabs listed."],
      ],
    });
    const events = await collect({
      config: makeConfig(server),
      apiKey: "test-key",
      userMessage: "what tabs are open?",
      adapters,
      consent,
      onEvent: () => undefined,
    });
    expect(events).toEqual([
      { type: "text", text: "Let me check. " },
      { type: "tool-request", request: { name: "listTabs", args: {} } },
      {
        type: "tool-result",
        request: { name: "listTabs", args: {} },
        result: { ok: true, value: [{ id: 1, title: "Docs", url: "https://docs.test" }] },
      },
      { type: "text", text: "Tabs listed." },
      { type: "done" },
    ]);
    expect(adapters.calls).toEqual(["listTabs"]);
    expect(consent).not.toHaveBeenCalled();
    const second = server.bodies[1] ?? "";
    expect(second).toContain("Let me check.");
    expect(second).toContain("[tool result] listTabs: [{");
  });

  it("routes write tools through consent and executes on approval", async () => {
    await server.close();
    server = await startFixtureServer({
      openaiScript: [[fence("openTab", { url: "https://x.test" })], ["Opened."]],
    });
    const events = await collect({
      config: makeConfig(server),
      apiKey: "test-key",
      userMessage: "open x",
      adapters,
      consent,
      onEvent: () => undefined,
    });
    expect(events).toEqual([
      { type: "tool-request", request: { name: "openTab", args: { url: "https://x.test" } } },
      {
        type: "tool-result",
        request: { name: "openTab", args: { url: "https://x.test" } },
        result: { ok: true, value: undefined },
      },
      { type: "text", text: "Opened." },
      { type: "done" },
    ]);
    expect(consent).toHaveBeenCalledTimes(1);
    expect(adapters.calls).toEqual(["openTab:https://x.test"]);
  });

  it("refuses a write when consent is denied and still answers", async () => {
    await server.close();
    server = await startFixtureServer({
      openaiScript: [[fence("openTab", { url: "https://x.test" })], ["Fine, skipping."]],
    });
    consent.mockResolvedValue(false);
    const events = await collect({
      config: makeConfig(server),
      apiKey: "test-key",
      userMessage: "open x",
      adapters,
      consent,
      onEvent: () => undefined,
    });
    expect(events).toEqual([
      { type: "tool-request", request: { name: "openTab", args: { url: "https://x.test" } } },
      {
        type: "tool-result",
        request: { name: "openTab", args: { url: "https://x.test" } },
        result: { ok: false, error: "refused: consent-denied" },
      },
      { type: "text", text: "Fine, skipping." },
      { type: "done" },
    ]);
    expect(adapters.calls).toEqual([]);
    const second = server.bodies[1] ?? "";
    expect(second).toContain("[tool result] openTab: error: refused: consent-denied");
  });

  it("refuses unknown tools without touching adapters", async () => {
    await server.close();
    server = await startFixtureServer({
      openaiScript: [[fence("exfiltrateCookies", {})], ["No."]],
    });
    const events = await collect({
      config: makeConfig(server),
      apiKey: "test-key",
      userMessage: "do it",
      adapters,
      consent,
      onEvent: () => undefined,
    });
    expect(events).toEqual([
      { type: "tool-request", request: { name: "exfiltrateCookies", args: {} } },
      {
        type: "tool-result",
        request: { name: "exfiltrateCookies", args: {} },
        result: { ok: false, error: "refused: unknown-tool" },
      },
      { type: "text", text: "No." },
      { type: "done" },
    ]);
    expect(adapters.calls).toEqual([]);
    expect(consent).not.toHaveBeenCalled();
  });

  it("executes at most two tool rounds and refuses the rest", async () => {
    await server.close();
    server = await startFixtureServer({
      openaiScript: [[listTabsFence], [listTabsFence], [listTabsFence]],
    });
    const events = await collect({
      config: makeConfig(server),
      apiKey: "test-key",
      userMessage: "tabs?",
      adapters,
      consent,
      onEvent: () => undefined,
    });
    const results = events.filter(
      (e): e is Extract<ChatEvent, { type: "tool-result" }> => e.type === "tool-result",
    );
    expect(results.length).toBe(3);
    expect(results[0]?.result.ok).toBe(true);
    expect(results[1]?.result.ok).toBe(true);
    expect(results[2]?.result).toEqual({ ok: false, error: "tool round limit reached" });
    expect(events[events.length - 1]?.type).toBe("done");
    expect(adapters.calls).toEqual(["listTabs", "listTabs"]);
    expect(server.bodies.length).toBe(3);
  });

  it("synthesizes the assistant turn when the model sends only a fence", async () => {
    await server.close();
    server = await startFixtureServer({ openaiScript: [[listTabsFence], ["Answer."]] });
    await collect({
      config: makeConfig(server),
      apiKey: "test-key",
      userMessage: "tabs?",
      adapters,
      consent,
      onEvent: () => undefined,
    });
    const second = JSON.parse(server.bodies[1] ?? "{}") as { messages: { role: string; content: string }[] };
    const assistant = second.messages.find((m) => m.role === "assistant");
    expect(assistant?.content).toBe(listTabsFence);
  });

  it("emits an error event when the provider fails", async () => {
    const events = await collect({
      config,
      apiKey: "wrong-key",
      userMessage: "hi",
      adapters,
      consent,
      onEvent: () => undefined,
    });
    expect(events.length).toBe(1);
    expect(events[0]?.type).toBe("error");
    expect(events[0]?.type === "error" && events[0].message).toContain("HTTP 401");
  });

  it("emits an error event when consent throws a non-Error", async () => {
    await server.close();
    server = await startFixtureServer({
      openaiScript: [[fence("openTab", { url: "https://x.test" })]],
    });
    const events = await collect({
      config: makeConfig(server),
      apiKey: "test-key",
      userMessage: "open x",
      adapters,
      consent: async () => {
        throw "nope";
      },
      onEvent: () => undefined,
    });
    expect(events).toEqual([
      { type: "tool-request", request: { name: "openTab", args: { url: "https://x.test" } } },
      { type: "error", message: "nope" },
    ]);
  });

  it("builds user content directly (unit)", () => {
    expect(buildUserContent("q", [], 1000)).toBe("q");
    const withTabs = buildUserContent(
      "q",
      [{ tabId: 1, origin: "https://a.test", text: "DATA", tokens: 1 }],
      100000,
    );
    expect(withTabs).toContain("q\n\n");
    expect(withTabs).toContain("https://a.test");
  });
});
