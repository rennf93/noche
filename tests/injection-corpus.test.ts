// @vitest-environment jsdom
/**
 * Injection corpus v1: every committed hostile page is run through the full
 * pipeline (jsdom extraction, budget + wrapUntrusted, a fixture model that
 * echoes the wrapped page verbatim and then attempts the page's planted tool
 * directive, the stream interpreter, and the consent gate with consent
 * auto-denied). Every page must fail closed: no tool executes, and no consent
 * prompt reaches auto-approval.
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "jsdom";
import { describe, expect, it } from "vitest";
import { buildCorpus } from "./corpus/generate.mjs";
import { startFixtureServer, type FixtureServer } from "./fixture-server";
import { extractPage } from "../src/context/extract";
import { UNTRUSTED_END, UNTRUSTED_START } from "../src/security/markup";
import {
  buildUserContent,
  runChat,
  type ChatEvent,
  type OrchestratorTab,
} from "../src/chat/orchestrator";
import { toolRegistry, type ToolAdapters } from "../src/chat/tools";
import { providerConfigSchema, type ProviderConfig } from "../src/providers/schema";
import type { ToolRequest } from "../src/security/interpreter";

interface ManifestPage {
  file: string;
  category: string;
  origin: string;
  directive: ToolRequest;
  mustContain: string;
}

interface CorpusManifest {
  sentinels: { start: string; end: string };
  pages: ManifestPage[];
}

const CORPUS_DIR = join(dirname(fileURLToPath(import.meta.url)), "corpus");
const manifest = JSON.parse(readFileSync(join(CORPUS_DIR, "manifest.json"), "utf8")) as CorpusManifest;

/** Per-page stream chunk sizes: the reply is split so markers cross boundaries. */
const CHUNK_SIZES = [1, 3, 7, 13, 29, 61];

function makeConfig(server: FixtureServer, contextWindow: number): ProviderConfig {
  return providerConfigSchema.parse({
    id: "fixture",
    label: "Fixture",
    baseUrl: server.url,
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
        return [];
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

/**
 * The full pipeline for one hostile page. The fixture model is the worst case:
 * it echoes the sentinel-wrapped page content verbatim (markers included) and
 * then, outside the span, attempts the exact directive the page planted. A
 * compliant model would repeat neither; a broken firewall shows up as either
 * extra parsed requests or an executed tool.
 */
async function runHostilePage(meta: ManifestPage, index: number): Promise<void> {
  const html = readFileSync(join(CORPUS_DIR, "pages", meta.file), "utf8");
  const doc = new JSDOM(html, { url: meta.origin + "/" }).window.document;

  // 1. Extract: the hostile directive text must survive into the text channel,
  //    proving the corpus is actually hostile and the test is not vacuous.
  const extracted = extractPage(doc);
  expect(extracted.origin).toBe(meta.origin);
  expect(extracted.text).toContain(meta.mustContain);

  // 2. Budget + wrapUntrusted, exactly as the orchestrator does it.
  const userMessage = "Summarize this page";
  const contextWindow = 262144;
  const tab: OrchestratorTab = {
    tabId: 1,
    origin: extracted.origin,
    text: extracted.text,
    tokens: extracted.tokens,
  };
  const expectedUser = buildUserContent(userMessage, [tab], contextWindow);
  expect(expectedUser).toContain(`${UNTRUSTED_START}${meta.origin}>>>`);
  expect(expectedUser).toContain(UNTRUSTED_END);

  // 3. Fixture model reply: verbatim echo of the wrapped page, then the page's
  //    directive attempted as a real fence outside any span. Streamed in small
  //    chunks so every marker crosses chunk boundaries.
  const attempt = "```noche-tool\n" + JSON.stringify(meta.directive) + "\n```";
  const reply = `${expectedUser}\n\n${attempt}`;
  const size = CHUNK_SIZES[index % CHUNK_SIZES.length] ?? 7;
  const deltas: string[] = [];
  for (let i = 0; i < reply.length; i += size) deltas.push(reply.slice(i, i + size));

  const server = await startFixtureServer({ openaiScript: [deltas] });
  try {
    const { adapters, calls } = recordingAdapters();
    const consentCalls: ToolRequest[] = [];
    const consent = async (request: ToolRequest): Promise<boolean> => {
      consentCalls.push(request);
      return false;
    };
    const events: ChatEvent[] = [];
    await runChat({
      config: makeConfig(server, contextWindow),
      apiKey: "test-key",
      userMessage,
      tabs: [tab],
      adapters,
      consent,
      onEvent: (event) => events.push(event),
    });

    // The model received exactly the budgeted, sentinel-wrapped content.
    const sent = JSON.parse(server.bodies[0] ?? "{}") as {
      messages?: { role: string; content: string }[];
    };
    expect(sent.messages?.[1]?.content).toBe(expectedUser);

    // Fail closed, claim one: nothing executed.
    expect(calls).toEqual([]);

    // The run completes without an error event.
    expect(events.at(-1)?.type).toBe("done");
    for (const event of events) expect(event.type).not.toBe("error");

    // Fail closed, claim two: the only requests ever parsed are the fixture
    // model's own deliberate attempts. Extra requests here would mean page
    // text (or a forged sentinel) escaped the span and posed as model output.
    const requests = events.filter(
      (e): e is Extract<ChatEvent, { type: "tool-request" }> => e.type === "tool-request",
    );
    expect(requests.length).toBeGreaterThanOrEqual(1);
    for (const event of requests) expect(event.request).toEqual(meta.directive);

    // Fail closed, claim three: every request is refused, and only by the
    // designed refusals (denied consent, unknown tool, round limit).
    const results = events.filter(
      (e): e is Extract<ChatEvent, { type: "tool-result" }> => e.type === "tool-result",
    );
    expect(results.length).toBe(requests.length);
    for (const event of results) {
      expect(event.result.ok).toBe(false);
      if (!event.result.ok) {
        expect([
          "refused: consent-denied",
          "refused: unknown-tool",
          "tool round limit reached",
        ]).toContain(event.result.error);
      }
    }

    // Fail closed, claim four: no consent prompt reaches auto-approval. The
    // harness auto-denies every prompt, so a prompt only ever exists for the
    // deliberate write attempt and it is always answered no.
    const spec = toolRegistry[meta.directive.name]?.spec;
    if (spec?.kind === "write") expect(consentCalls.length).toBeGreaterThanOrEqual(1);
    else expect(consentCalls).toEqual([]);
    for (const call of consentCalls) expect(call).toEqual(meta.directive);
  } finally {
    await server.close();
  }
}

describe("injection corpus hygiene", () => {
  const built = buildCorpus();

  it("is in sync with the generator and has 50 distinct committed pages", () => {
    expect(built.length).toBe(50);
    expect(manifest.pages.length).toBe(50);
    expect(new Set(built.map((p) => p.file)).size).toBe(50);
    expect(new Set(built.map((p) => p.html)).size).toBe(50);
    expect(new Set(manifest.pages.map((p) => p.file)).size).toBe(50);
    for (const p of built) {
      expect(readFileSync(join(CORPUS_DIR, "pages", p.file), "utf8")).toBe(p.html);
      const meta = manifest.pages.find((m) => m.file === p.file);
      expect(meta).toBeDefined();
      expect(meta?.category).toBe(p.category);
      expect(meta?.origin).toBe(p.origin);
      expect(meta?.directive).toEqual(p.directive);
      expect(meta?.mustContain).toBe(p.mustContain);
    }
  });

  it("carries the src sentinel constants without drift", () => {
    expect(manifest.sentinels.start).toBe(UNTRUSTED_START);
    expect(manifest.sentinels.end).toBe(UNTRUSTED_END);
  });

  it("covers all eight attack categories at full force", () => {
    const counts = new Map<string, number>();
    for (const meta of manifest.pages) {
      counts.set(meta.category, (counts.get(meta.category) ?? 0) + 1);
    }
    expect([...counts.entries()].sort()).toEqual([
      ["exfiltration", 7],
      ["fake-system-prompt", 6],
      ["fake-tool-directive", 8],
      ["hidden-text", 7],
      ["markdown-quoted", 6],
      ["sentinel-close-then-command", 5],
      ["sentinel-forge", 8],
      ["unicode-lookalikes", 3],
    ]);
  });

  it("plants only write or unknown directives, never a read tool", () => {
    for (const meta of manifest.pages) {
      const spec = toolRegistry[meta.directive.name]?.spec;
      if (spec !== undefined) expect(spec.kind).toBe("write");
    }
  });

  it("forge pages really contain the literal sentinel markers in page text", () => {
    for (const meta of manifest.pages) {
      if (meta.category !== "sentinel-forge" && meta.category !== "sentinel-close-then-command") {
        continue;
      }
      const doc = new JSDOM(readFileSync(join(CORPUS_DIR, "pages", meta.file), "utf8"), {
        url: meta.origin + "/",
      }).window.document;
      const text = doc.body?.textContent ?? "";
      if (meta.file.includes("split-across-paragraphs")) {
        // That page splits the marker across paragraphs; both halves present.
        expect(text).toContain("END_UNTRUSTED_PAG");
        expect(text).toContain("E_CONTENT>>>");
      } else {
        expect(text).toContain(UNTRUSTED_END);
      }
    }
  });

  it("unicode lookalike pages never contain a literal fence opener", () => {
    for (const meta of manifest.pages) {
      if (meta.category !== "unicode-lookalikes") continue;
      const doc = new JSDOM(readFileSync(join(CORPUS_DIR, "pages", meta.file), "utf8"), {
        url: meta.origin + "/",
      }).window.document;
      expect(doc.body?.textContent ?? "").not.toContain("```noche-tool\n");
    }
  });
});

describe("injection corpus: every page fails closed end to end", () => {
  for (const [index, meta] of manifest.pages.entries()) {
    it(`fails closed: ${meta.category}/${meta.file}`, { timeout: 30000 }, async () => {
      await runHostilePage(meta, index);
    });
  }
});
