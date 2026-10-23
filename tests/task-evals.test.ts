/**
 * Task evals v1: 30 deterministic, machine-checked tasks against fixture
 * models (loopback HTTP only, no network) covering tab-context budgeting,
 * origin labeling, tool round-trips, consent denial paths, skill slash
 * matching and SKILL.md parsing. Every task asserts exact outcomes, never
 * model judgment.
 */
import { describe, expect, it } from "vitest";
import { startFixtureServer } from "./fixture-server";
import { providerConfigSchema, type ProviderConfig } from "../src/providers/schema";
import {
  runChat,
  type ChatEvent,
  type OrchestratorTab,
} from "../src/chat/orchestrator";
import type { ToolAdapters } from "../src/chat/tools";
import type { ToolRequest } from "../src/security/interpreter";
import { UNTRUSTED_END, UNTRUSTED_START, wrapUntrusted } from "../src/security/markup";
import { allocateBudget } from "../src/context/budget";
import { matchSkill, parseSkillMd, type SkillMeta } from "../src/skills/parse";

function fence(name: string, args: unknown): string {
  return "```noche-tool\n" + JSON.stringify({ name, args }) + "\n```";
}

function makeConfig(baseUrl: string, contextWindow = 262144): ProviderConfig {
  return providerConfigSchema.parse({
    id: "fixture",
    label: "Fixture",
    baseUrl,
    wire: "openai-completions",
    auth: { type: "apiKey", headerStyle: "bearer" },
    models: [{ id: "north", label: "North", contextWindow }],
  });
}

function recordingAdapters(): { adapters: ToolAdapters; calls: string[] } {
  const calls: string[] = [];
  return {
    calls,
    adapters: {
      listTabs: async () => {
        calls.push("listTabs");
        return [{ id: 7, title: "Docs", url: "https://docs.test" }];
      },
      openTab: async (url) => {
        calls.push("openTab:" + url);
      },
      closeTab: async (tabId) => {
        calls.push("closeTab:" + tabId);
      },
      copyText: async (text) => {
        calls.push("copyText:" + text);
      },
    },
  };
}

interface RunOptions {
  script: string[][];
  tabs?: OrchestratorTab[];
  userMessage?: string;
  contextWindow?: number;
  consent?: (request: ToolRequest) => Promise<boolean>;
}

/** One full runChat round against the fixture server; server is closed after. */
async function runWith(options: RunOptions): Promise<{
  events: ChatEvent[];
  calls: string[];
  bodies: string[];
  consentCalls: ToolRequest[];
}> {
  const server = await startFixtureServer({ openaiScript: options.script });
  try {
    const { adapters, calls } = recordingAdapters();
    const consentCalls: ToolRequest[] = [];
    const behavior = options.consent ?? (async (): Promise<boolean> => true);
    const consent = async (request: ToolRequest): Promise<boolean> => {
      consentCalls.push(request);
      return behavior(request);
    };
    const events: ChatEvent[] = [];
    await runChat({
      config: makeConfig(server.url, options.contextWindow),
      apiKey: "test-key",
      userMessage: options.userMessage ?? "q",
      tabs: options.tabs ?? [],
      adapters,
      consent,
      onEvent: (event) => events.push(event),
    });
    return { events, calls, bodies: server.bodies, consentCalls };
  } finally {
    await server.close();
  }
}

function tab(id: number, origin: string, text: string, active = false): OrchestratorTab {
  return { tabId: id, origin, text, tokens: Math.ceil(text.length / 4), active };
}

/** The user message body the orchestrator sent, parsed from the captured request. */
function userBodyOf(bodies: string[], index = 0): string {
  const sent = JSON.parse(bodies[index] ?? "{}") as {
    messages?: { role: string; content: string }[];
  };
  return sent.messages?.[1]?.content ?? "";
}

function resultsOf(events: ChatEvent[]): Extract<ChatEvent, { type: "tool-result" }>[] {
  return events.filter(
    (e): e is Extract<ChatEvent, { type: "tool-result" }> => e.type === "tool-result",
  );
}

describe("task evals: tab-context budgeting", () => {
  it("1. every tab fits fully when the window allows it", () => {
    const out = allocateBudget({
      contextWindow: 8192,
      tabs: [
        { tabId: 1, tokens: 10 },
        { tabId: 2, tokens: 20 },
        { tabId: 3, tokens: 30 },
      ],
    });
    expect(out).toEqual([
      { tabId: 1, allowed: 10, complete: true },
      { tabId: 2, allowed: 20, complete: true },
      { tabId: 3, allowed: 30, complete: true },
    ]);
  });

  it("2. the active tab gets triple weight on overflow", () => {
    // usable = 1656 - 1024 - 512 = 120; weights 1:3:1 share 24:72:24.
    const out = allocateBudget({
      contextWindow: 1656,
      tabs: [
        { tabId: 1, tokens: 60 },
        { tabId: 2, tokens: 60, active: true },
        { tabId: 3, tokens: 60 },
      ],
    });
    expect(out.map((a) => a.allowed)).toEqual([24, 60, 24]);
    expect(out.map((a) => a.complete)).toEqual([false, true, false]);
  });

  it("3. zero-token tabs are skipped and never steal budget", () => {
    const out = allocateBudget({
      contextWindow: 1544, // usable 8, all of it goes to the non-empty tab
      tabs: [
        { tabId: 1, tokens: 0 },
        { tabId: 2, tokens: 10 },
        { tabId: 3, tokens: 0 },
      ],
    });
    expect(out).toEqual([
      { tabId: 1, allowed: 0, complete: true },
      { tabId: 2, allowed: 8, complete: false },
      { tabId: 3, allowed: 0, complete: true },
    ]);
  });

  it("4. reserveOutput and the system reserve shrink usable budget", () => {
    // usable = 2048 - 1024 - 512 = 512; two equal tabs split it 256/256.
    const out = allocateBudget({
      contextWindow: 2048,
      reserveOutput: 1024,
      tabs: [
        { tabId: 1, tokens: 400 },
        { tabId: 2, tokens: 400 },
      ],
    });
    expect(out.map((a) => a.allowed)).toEqual([256, 256]);
  });

  it("5. the prompt contains every chunk, wrapped, when everything fits", async () => {
    const a = tab(1, "https://a.test", "ALPHA PAGE TEXT");
    const b = tab(2, "https://b.test", "BETA PAGE TEXT");
    const { bodies } = await runWith({
      script: [["ok"]],
      tabs: [a, b],
      userMessage: "compare",
    });
    const expected =
      "compare\n\n" +
      wrapUntrusted(a.origin, a.text) +
      "\n\n" +
      wrapUntrusted(b.origin, b.text);
    expect(userBodyOf(bodies)).toBe(expected);
  });

  it("6. the prompt collapses to the bare question when nothing fits", async () => {
    const { bodies } = await runWith({
      script: [["ok"]],
      contextWindow: 1088,
      tabs: [tab(1, "https://a.test", "DATA", true)],
      userMessage: "q",
    });
    expect(userBodyOf(bodies)).toBe("q");
  });

  it("7. the prompt truncates an overflowing tab to its exact allowance", async () => {
    const a = tab(1, "https://a.test", "A".repeat(16));
    const b = tab(2, "https://b.test", "B".repeat(400));
    // usable = 1600 - 1536 = 64 tokens; equal weights give each 32 tokens,
    // so A keeps all 16 chars and B keeps exactly 128 of 400.
    const { bodies } = await runWith({
      script: [["ok"]],
      contextWindow: 1600,
      tabs: [a, b],
      userMessage: "q",
    });
    const user = userBodyOf(bodies);
    expect(user).toContain("A".repeat(16));
    expect(user).toContain("B".repeat(128));
    expect(user).not.toContain("B".repeat(129));
  });

  it("8. an active tab wins the overflow share in the prompt", async () => {
    const a = tab(1, "https://a.test", "A".repeat(160));
    const b = tab(2, "https://b.test", "B".repeat(160), true);
    // usable 64; weights 1:3 give A 16 tokens (64 chars) and B 40 (all 160).
    const { bodies } = await runWith({
      script: [["ok"]],
      contextWindow: 1600,
      tabs: [a, b],
      userMessage: "q",
    });
    const user = userBodyOf(bodies);
    expect(user).toContain("A".repeat(64));
    expect(user).not.toContain("A".repeat(65));
    expect(user).toContain("B".repeat(160));
  });
});

describe("task evals: origin labeling", () => {
  it("9. each chunk is labeled with its own origin, in order", async () => {
    const a = tab(1, "https://alpha.test", "ALPHA TEXT");
    const b = tab(2, "https://beta.test", "BETA TEXT");
    const { bodies } = await runWith({ script: [["ok"]], tabs: [a, b], userMessage: "q" });
    const user = userBodyOf(bodies);
    const startA = user.indexOf(`${UNTRUSTED_START}${a.origin}>>>`);
    const textA = user.indexOf(a.text);
    const startB = user.indexOf(`${UNTRUSTED_START}${b.origin}>>>`);
    const textB = user.indexOf(b.text);
    expect(startA).toBeGreaterThanOrEqual(0);
    expect(startB).toBeGreaterThan(startA);
    expect(textA).toBeGreaterThan(startA);
    expect(textA).toBeLessThan(startB);
    expect(textB).toBeGreaterThan(startB);
  });

  it("10. a benign chunk appears exactly once inside one closed span", async () => {
    const a = tab(1, "https://solo.test", "SOLO PAGE TEXT");
    const { bodies } = await runWith({ script: [["ok"]], tabs: [a], userMessage: "q" });
    const user = userBodyOf(bodies);
    const start = user.indexOf(`${UNTRUSTED_START}${a.origin}>>>`);
    const end = user.indexOf(UNTRUSTED_END);
    expect(start).toBeGreaterThanOrEqual(0);
    expect(user.indexOf(a.text)).toBeGreaterThan(start);
    expect(end).toBeGreaterThan(user.indexOf(a.text));
    expect(user.indexOf(UNTRUSTED_END, end + 1)).toBe(-1);
  });

  it("11. an empty tab contributes no origin label", async () => {
    const a = tab(1, "https://real.test", "REAL TEXT");
    const empty = tab(2, "https://empty.test", "");
    const { bodies } = await runWith({ script: [["ok"]], tabs: [a, empty], userMessage: "q" });
    const user = userBodyOf(bodies);
    expect(user).toContain("https://real.test");
    expect(user).not.toContain("https://empty.test");
  });
});

describe("task evals: tool round-trips", () => {
  it("12. an approved openTab executes through the fake adapter", async () => {
    const { events, calls } = await runWith({
      script: [[fence("openTab", { url: "https://example.test/a" })], ["Opened."]],
      userMessage: "open a",
    });
    const results = resultsOf(events);
    expect(results).toEqual([
      {
        type: "tool-result",
        request: { name: "openTab", args: { url: "https://example.test/a" } },
        result: { ok: true, value: undefined },
      },
    ]);
    expect(calls).toEqual(["openTab:https://example.test/a"]);
    expect(events.at(-1)?.type).toBe("done");
  });

  it("13. an approved copyText carries the exact payload", async () => {
    const payload = "meet notes from https://notes.test";
    const { events, calls } = await runWith({
      script: [[fence("copyText", { text: payload })], ["Copied."]],
      userMessage: "save this",
    });
    expect(resultsOf(events)[0]?.result).toEqual({ ok: true, value: undefined });
    expect(calls).toEqual([`copyText:${payload}`]);
  });

  it("14. an approved closeTab passes the tab id through", async () => {
    const { events, calls } = await runWith({
      script: [[fence("closeTab", { tabId: 42 })], ["Closed."]],
      userMessage: "close it",
    });
    expect(resultsOf(events)[0]?.result).toEqual({ ok: true, value: undefined });
    expect(calls).toEqual(["closeTab:42"]);
  });

  it("15. a third tool round is refused by the round limit", async () => {
    const { events, calls, bodies } = await runWith({
      script: [[fence("listTabs", {})], [fence("listTabs", {})], [fence("listTabs", {})]],
      userMessage: "tabs?",
    });
    const results = resultsOf(events);
    expect(results.length).toBe(3);
    expect(results[0]?.result.ok).toBe(true);
    expect(results[1]?.result.ok).toBe(true);
    expect(results[2]?.result).toEqual({ ok: false, error: "tool round limit reached" });
    expect(calls).toEqual(["listTabs", "listTabs"]);
    expect(bodies.length).toBe(3);
    expect(events.at(-1)?.type).toBe("done");
  });

  it("16. an unknown tool never reaches an adapter or consent", async () => {
    const { events, calls, consentCalls } = await runWith({
      script: [[fence("publishPage", { target: "https://example.test" })], ["No."]],
      userMessage: "publish",
    });
    expect(resultsOf(events)[0]?.result).toEqual({ ok: false, error: "refused: unknown-tool" });
    expect(calls).toEqual([]);
    expect(consentCalls).toEqual([]);
  });
});

describe("task evals: consent denial paths", () => {
  const deny = async (): Promise<boolean> => false;

  it("17. a denied openTab refuses without executing and feeds the refusal back", async () => {
    const { events, calls, bodies } = await runWith({
      script: [[fence("openTab", { url: "https://example.test/denied" })], ["Skipping."]],
      userMessage: "open it",
      consent: deny,
    });
    expect(resultsOf(events)).toEqual([
      {
        type: "tool-result",
        request: { name: "openTab", args: { url: "https://example.test/denied" } },
        result: { ok: false, error: "refused: consent-denied" },
      },
    ]);
    expect(calls).toEqual([]);
    expect(bodies[1]).toContain("error: refused: consent-denied");
  });

  it("18. a denied closeTab refuses and the run still completes", async () => {
    const { events, calls } = await runWith({
      script: [[fence("closeTab", { tabId: 9 })], ["Left open."]],
      userMessage: "close it",
      consent: deny,
    });
    expect(resultsOf(events)[0]?.result.ok).toBe(false);
    expect(calls).toEqual([]);
    expect(events.at(-1)?.type).toBe("done");
  });

  it("19. a denied copyText prompts with the exact request", async () => {
    const payload = "secret scrap 12";
    const { consentCalls } = await runWith({
      script: [[fence("copyText", { text: payload })], ["Fine."]],
      userMessage: "copy",
      consent: deny,
    });
    expect(consentCalls).toEqual([{ name: "copyText", args: { text: payload } }]);
  });

  it("20. in a mixed round the read runs and the denied write does not", async () => {
    const { events, calls, consentCalls } = await runWith({
      script: [[`${fence("listTabs", {})} then ${fence("openTab", { url: "https://x.test" })}`], ["Done."]],
      userMessage: "check and open",
      consent: deny,
    });
    const results = resultsOf(events);
    expect(results[0]?.request).toEqual({ name: "listTabs", args: {} });
    expect(results[0]?.result.ok).toBe(true);
    expect(results[1]?.request).toEqual({ name: "openTab", args: { url: "https://x.test" } });
    expect(results[1]?.result).toEqual({ ok: false, error: "refused: consent-denied" });
    expect(calls).toEqual(["listTabs"]);
    expect(consentCalls).toEqual([{ name: "openTab", args: { url: "https://x.test" } }]);
  });

  it("21. consent throwing surfaces an error event and executes nothing", async () => {
    const { events, calls } = await runWith({
      script: [[fence("openTab", { url: "https://x.test" })]],
      userMessage: "open",
      consent: async () => {
        throw new Error("prompt unavailable");
      },
    });
    expect(events).toEqual([
      { type: "tool-request", request: { name: "openTab", args: { url: "https://x.test" } } },
      { type: "error", message: "prompt unavailable" },
    ]);
    expect(calls).toEqual([]);
  });
});

describe("task evals: skill slash matching", () => {
  const skills: SkillMeta[] = [
    { name: "cite-check", description: "Check claims", disableModelInvocation: false },
    { name: "sum", description: "Summarize", disableModelInvocation: false },
    { name: "summarize", description: "Deep summary", disableModelInvocation: false },
  ];

  it("22. an exact /name triggers with empty rest", () => {
    const match = matchSkill("/sum", skills);
    expect(match?.skill.name).toBe("sum");
    expect(match?.rest).toBe("");
  });

  it("23. arguments after the name travel as rest", () => {
    const match = matchSkill("/cite-check claim one two", skills);
    expect(match?.skill.name).toBe("cite-check");
    expect(match?.rest).toBe("claim one two");
  });

  it("24. a longer name never fires a prefix skill", () => {
    expect(matchSkill("/summarize now", skills)?.skill.name).toBe("summarize");
    expect(matchSkill("/summar", skills)).toBeUndefined();
    expect(matchSkill("/sumx", skills)).toBeUndefined();
  });

  it("25. matching is case sensitive and array order breaks ties", () => {
    expect(matchSkill("/Cite-check x", skills)).toBeUndefined();
    const dupes: SkillMeta[] = [
      { name: "dup", description: "first", disableModelInvocation: false },
      { name: "dup", description: "second", disableModelInvocation: false },
    ];
    expect(matchSkill("/dup x", dupes)?.skill.description).toBe("first");
  });
});

describe("task evals: SKILL.md parsing", () => {
  it("26. parses frontmatter, the disable default and the body", () => {
    const result = parseSkillMd(
      [
        "---",
        "name: deploy-notes",
        "description: Posts release notes",
        "---",
        "",
        "# Deploy notes",
        "",
        "Summarize merged PRs.",
      ].join("\n"),
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.skill.meta).toEqual({
        name: "deploy-notes",
        description: "Posts release notes",
        disableModelInvocation: false,
      });
      expect(result.skill.body).toBe("# Deploy notes\n\nSummarize merged PRs.");
    }
  });

  it("27. strips quotes only as a matching pair", () => {
    const result = parseSkillMd(
      [
        "---",
        'name: "quoted"',
        "description: 'single'",
        'description2: "oops',
        "---",
        "body",
      ].join("\n"),
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.skill.meta.name).toBe("quoted");
      expect(result.skill.body).toBe("body");
    }
  });

  it("28. disable-model-invocation must be true or false", () => {
    const bad = parseSkillMd(
      ["---", "name: x", "description: y", "disable-model-invocation: yes", "---", "b"].join("\n"),
    );
    expect(bad).toEqual({ ok: false, error: "disable-model-invocation must be true or false" });
    for (const value of ["true", "false"]) {
      const result = parseSkillMd(
        ["---", "name: x", "description: y", `disable-model-invocation: ${value}`, "---", "b"].join("\n"),
      );
      expect(result.ok).toBe(true);
      if (result.ok) expect(result.skill.meta.disableModelInvocation).toBe(value === "true");
    }
  });

  it("29. missing required structure is an error, never a guess", () => {
    expect(parseSkillMd("name: x\n---\nbody")).toEqual({
      ok: false,
      error: "missing frontmatter open marker",
    });
    expect(parseSkillMd("---\nname: x\ndescription: y\n")).toEqual({
      ok: false,
      error: "missing frontmatter close marker",
    });
    expect(parseSkillMd("---\ndescription: y\n---\nbody")).toEqual({
      ok: false,
      error: "frontmatter missing name",
    });
    expect(parseSkillMd("---\nname: x\n---\nbody")).toEqual({
      ok: false,
      error: "frontmatter missing description",
    });
  });

  it("30. unknown keys are ignored and comment lines are skipped", () => {
    const result = parseSkillMd(
      ["---", "name: x", "description: y", "version: 9", "# internal note", "", "---", "b"].join("\n"),
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.skill.meta).toEqual({
        name: "x",
        description: "y",
        disableModelInvocation: false,
      });
    }
  });
});
