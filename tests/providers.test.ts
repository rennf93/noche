import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { startFixtureServer, type FixtureServer } from "./fixture-server";
import { createSseParser } from "../src/providers/sse";
import { defaultModel, providerConfigSchema, type ProviderConfig } from "../src/providers/schema";
import { streamOpenAIChat } from "../src/providers/openai";
import { streamAnthropicChat } from "../src/providers/anthropic";
import { streamChat } from "../src/providers/index";

let server: FixtureServer;
let localFleet: ProviderConfig;
let anthropicish: ProviderConfig;

beforeEach(async () => {
  server = await startFixtureServer();
  localFleet = providerConfigSchema.parse({
    id: "local-fleet",
    label: "Local fleet",
    baseUrl: server.url,
    wire: "openai-completions",
    auth: { type: "apiKey", headerStyle: "bearer" },
    models: [{ id: "north", label: "North", contextWindow: 262144 }],
  });
  anthropicish = providerConfigSchema.parse({
    id: "anth-fixture",
    label: "Anthropic fixture",
    baseUrl: server.url,
    wire: "anthropic-messages",
    auth: { type: "apiKey", headerStyle: "x-api-key" },
    models: [
      { id: "m1", contextWindow: 200000, default: true },
      { id: "m2", contextWindow: 100000 },
    ],
  });
});

afterEach(async () => {
  await server.close();
});

describe("sse parser", () => {
  it("parses events across chunk boundaries, CRLF, comments and multi-line data", () => {
    const parser = createSseParser();
    expect(parser.feed("data: a\n\n")).toEqual([{ data: "a" }]);
    expect(parser.feed("data:b\n\n")).toEqual([{ data: "b" }]);
    expect(parser.feed("data: par")).toEqual([]);
    expect(parser.feed("tial\r\n\r")).toEqual([]);
    expect(parser.feed("\n")).toEqual([{ data: "partial" }]);
    expect(parser.feed(": comment\n\n")).toEqual([]);
    expect(parser.feed("event: x\ndata: l1\ndata: l2\n\n")).toEqual([
      { event: "x", data: "l1\nl2" },
    ]);
    expect(parser.feed("data")).toEqual([]);
    expect(parser.feed("without-colon\n\n")).toEqual([]);
    expect(parser.feed("event: tail\ndata: end-no-newline")).toEqual([]);
    expect(parser.end()).toEqual([{ event: "tail", data: "end-no-newline" }]);
    expect(parser.end()).toEqual([]);
  });
});

describe("provider schema", () => {
  it("fills defaults and validates", () => {
    const parsed = providerConfigSchema.parse({
      id: "p",
      label: "P",
      baseUrl: "http://localhost:9991",
      wire: "openai-completions",
      auth: { type: "none" },
      models: [{ id: "m", contextWindow: 8192 }],
    });
    expect(parsed.models[0]?.reasoning).toBe(false);
    expect(parsed.models[0]?.default).toBe(false);
    expect(parsed.auth).toEqual({ type: "none" });
    const withKey = providerConfigSchema.parse({
      id: "p2",
      label: "P2",
      baseUrl: "http://localhost:9992",
      wire: "anthropic-messages",
      auth: { type: "apiKey" },
      models: [{ id: "m", contextWindow: 8192 }],
    });
    expect(withKey.auth.type === "apiKey" ? withKey.auth.headerStyle : "fail").toBe("bearer");
  });

  it("rejects bad configs", () => {
    const base = {
      id: "p",
      label: "P",
      baseUrl: "http://localhost:9991",
      wire: "openai-completions",
      auth: { type: "none" },
      models: [{ id: "m", contextWindow: 8192 }],
    };
    expect(providerConfigSchema.safeParse({ ...base, wire: "grpc" }).success).toBe(false);
    expect(providerConfigSchema.safeParse({ ...base, baseUrl: "not-a-url" }).success).toBe(false);
    expect(providerConfigSchema.safeParse({ ...base, models: [] }).success).toBe(false);
    expect(providerConfigSchema.safeParse({ ...base, auth: { type: "oauth" } }).success).toBe(false);
    expect(providerConfigSchema.safeParse({ ...base, id: "" }).success).toBe(false);
  });

  it("picks the default model, else the first, and guards empty catalogs", () => {
    expect(defaultModel(anthropicish).id).toBe("m1");
    const unflagged = providerConfigSchema.parse({
      id: "u",
      label: "U",
      baseUrl: "http://localhost:1",
      wire: "openai-completions",
      auth: { type: "none" },
      models: [{ id: "only", contextWindow: 8 }],
    });
    expect(defaultModel(unflagged).id).toBe("only");
    expect(() => defaultModel({ ...unflagged, models: [] })).toThrow("no models");
  });
});

describe("openai wire", () => {
  it("streams text from the fixture, stopping at [DONE]", async () => {
    const got: string[] = [];
    await streamOpenAIChat(
      localFleet,
      defaultModel(localFleet),
      [{ role: "user", content: "hi" }],
      { onText: (t) => got.push(t) },
      "test-key",
    );
    expect(got.join("")).toBe("Hello");
  });

  it("handles streams that end without [DONE]", async () => {
    const undoneServer = await startFixtureServer({ openaiUndone: true });
    try {
      const got: string[] = [];
      const cfg = providerConfigSchema.parse({ ...localFleet, baseUrl: undoneServer.url });
      await streamOpenAIChat(
        cfg,
        defaultModel(cfg),
        [{ role: "user", content: "hi" }],
        { onText: (t) => got.push(t) },
      );
      expect(got.join("")).toBe("A");
    } finally {
      await undoneServer.close();
    }
  });

  it("emits a final unterminated data event via end()", async () => {
    const tailServer = await startFixtureServer({ openaiTail: true });
    try {
      const got: string[] = [];
      const cfg = providerConfigSchema.parse({ ...localFleet, baseUrl: tailServer.url });
      await streamOpenAIChat(
        cfg,
        defaultModel(cfg),
        [{ role: "user", content: "hi" }],
        { onText: (t) => got.push(t) },
      );
      expect(got.join("")).toBe("AB");
    } finally {
      await tailServer.close();
    }
  });

  it("surfaces HTTP errors with status and body", async () => {
    await expect(
      streamOpenAIChat(
        localFleet,
        defaultModel(localFleet),
        [{ role: "user", content: "hi" }],
        { onText: () => undefined },
        "wrong-key",
      ),
    ).rejects.toThrow("HTTP 401");
  });

  it("throws on a null body", async () => {
    const fetchStub = vi.fn().mockResolvedValue({ ok: true, body: null }) as unknown as typeof fetch;
    await expect(
      streamOpenAIChat(
        localFleet,
        defaultModel(localFleet),
        [{ role: "user", content: "hi" }],
        { onText: () => undefined },
        undefined,
        fetchStub,
      ),
    ).rejects.toThrow("empty response body");
  });
});

describe("anthropic wire", () => {
  it("streams text deltas and stops at message_stop", async () => {
    const got: string[] = [];
    await streamAnthropicChat(
      anthropicish,
      defaultModel(anthropicish),
      [
        { role: "system", content: "be brief" },
        { role: "user", content: "hi" },
      ],
      { onText: (t) => got.push(t) },
      "test-key",
    );
    expect(got.join("")).toBe("world");
  });

  it("handles streams that end without message_stop and skips empty data", async () => {
    const undoneServer = await startFixtureServer({ anthropicUndone: true });
    try {
      const got: string[] = [];
      const cfg = providerConfigSchema.parse({ ...anthropicish, baseUrl: undoneServer.url });
      await streamAnthropicChat(
        cfg,
        cfg.models[1],
        [{ role: "user", content: "hi" }],
        { onText: (t) => got.push(t) },
      );
      expect(got.join("")).toBe("X");
    } finally {
      await undoneServer.close();
    }
  });

  it("emits a final unterminated delta via end()", async () => {
    const tailServer = await startFixtureServer({ anthropicTail: true });
    try {
      const got: string[] = [];
      const cfg = providerConfigSchema.parse({ ...anthropicish, baseUrl: tailServer.url });
      await streamAnthropicChat(
        cfg,
        defaultModel(cfg),
        [{ role: "user", content: "hi" }],
        { onText: (t) => got.push(t) },
      );
      expect(got.join("")).toBe("Y");
    } finally {
      await tailServer.close();
    }
  });

  it("surfaces HTTP errors", async () => {
    await expect(
      streamAnthropicChat(
        anthropicish,
        defaultModel(anthropicish),
        [{ role: "user", content: "hi" }],
        { onText: () => undefined },
        "wrong-key",
      ),
    ).rejects.toThrow("HTTP 401");
  });

  it("throws on a null body", async () => {
    const fetchStub = vi.fn().mockResolvedValue({ ok: true, body: null }) as unknown as typeof fetch;
    await expect(
      streamAnthropicChat(
        anthropicish,
        defaultModel(anthropicish),
        [{ role: "user", content: "hi" }],
        { onText: () => undefined },
        undefined,
        fetchStub,
      ),
    ).rejects.toThrow("empty response body");
  });
});

describe("streamChat dispatch", () => {
  it("routes by wire and resolves model ids with fallback", async () => {
    const got: string[] = [];
    await streamChat({
      config: localFleet,
      messages: [{ role: "user", content: "hi" }],
      callbacks: { onText: (t) => got.push(t) },
      apiKey: "test-key",
    });
    expect(got.join("")).toBe("Hello");
    const got2: string[] = [];
    await streamChat({
      config: anthropicish,
      messages: [{ role: "user", content: "hi" }],
      callbacks: { onText: (t) => got2.push(t) },
      apiKey: "test-key",
      modelId: "m2",
    });
    expect(got2.join("")).toBe("world");
    const got3: string[] = [];
    await streamChat({
      config: anthropicish,
      messages: [{ role: "user", content: "hi" }],
      callbacks: { onText: (t) => got3.push(t) },
      apiKey: "test-key",
      modelId: "does-not-exist",
    });
    expect(got3.join("")).toBe("world");
  });

  it("threads an abort signal into the wire fetch (stop while streaming)", async () => {
    const controller = new AbortController();
    const saw: { signal?: AbortSignal | null } = {};
    const fetchStub = vi.fn((_url: RequestInfo | URL, init?: RequestInit) => {
      saw.signal = init?.signal;
      return new Promise<Response>((_resolve, reject) => {
        controller.signal.addEventListener("abort", () => reject(new Error("aborted")), {
          once: true,
        });
      });
    }) as unknown as typeof fetch;
    vi.stubGlobal("fetch", fetchStub);
    try {
      const pending = streamChat({
        config: localFleet,
        messages: [{ role: "user", content: "hi" }],
        callbacks: { onText: () => undefined },
        apiKey: "test-key",
        signal: controller.signal,
      });
      controller.abort();
      await expect(pending).rejects.toThrow("aborted");
      expect(saw.signal).toBe(controller.signal);
    } finally {
      vi.unstubAllGlobals();
    }
  });
});
