import "fake-indexeddb/auto";
import { describe, expect, it } from "vitest";
import {
  parseHistoryQuery,
  parseHistoryRequest,
  parseHistoryResponse,
  parsePageRecord,
  parseTranscriptMessage,
  parseTranscriptRecord,
  type HistoryRequest,
  type HistoryResponse,
} from "../src/history/protocol";
import {
  DEFAULT_SEARCH_LIMIT,
  searchHistory,
  searchStoredHistory,
  type HistoryQuery,
  type SearchHit,
} from "../src/history/search";
import {
  appendMessage,
  openHistoryStore,
  type PageRecord,
  type TranscriptMessage,
  type TranscriptRecord,
} from "../src/history/store";

const DAY = 24 * 60 * 60 * 1000;
const NOW = 1_700_000_000_000;

const turn = (text: string, role: "user" | "assistant" = "user"): TranscriptMessage => ({
  role,
  text,
  at: NOW,
});

const transcript = (overrides: Partial<TranscriptRecord> = {}): TranscriptRecord => ({
  id: "t1",
  title: "Rust async chat",
  surface: "sidepanel",
  startedAt: NOW - 2 * DAY,
  updatedAt: NOW - 1 * DAY,
  messages: [turn("explain rust traits"), turn("traits are like interfaces", "assistant")],
  ...overrides,
});

const page = (overrides: Partial<PageRecord> = {}): PageRecord => ({
  id: "p1",
  url: "https://example.com/page",
  title: "Example Domain",
  lastVisitTime: NOW - 1 * DAY,
  visitCount: 2,
  ...overrides,
});

describe("history store", () => {
  it("puts, gets, deletes and lists transcripts and pages", async () => {
    const store = await openHistoryStore("history-basic");
    await store.putTranscript(transcript());
    await store.putTranscript(transcript({ id: "t2" }));
    await store.putPage(page());
    await store.putPage(page({ id: "p2", url: "https://other.test/" }));
    expect((await store.getTranscript("t1"))?.title).toBe("Rust async chat");
    expect(await store.getTranscript("missing")).toBeUndefined();
    expect(await store.getPage("https://other.test/")).toBeDefined();
    expect(await store.getPage("https://missing.test/")).toBeUndefined();
    expect((await store.allTranscripts()).length).toBe(2);
    expect((await store.allPages()).length).toBe(2);
    await store.deleteTranscript("t1");
    await store.deletePage("https://other.test/");
    expect((await store.allTranscripts()).length).toBe(1);
    expect((await store.allPages()).length).toBe(1);
  });

  it("accepts an explicit database name and factory", async () => {
    const store = await openHistoryStore("history-explicit", indexedDB);
    await store.putPage(page());
    expect((await store.allPages()).length).toBe(1);
  });

  it("rejects when the open request errors", async () => {
    const failingOpen = {
      open: () => {
        const req: Record<string, unknown> = {};
        Object.defineProperty(req, "then", { value: undefined });
        setTimeout(() => (req.onerror as () => void)?.(), 0);
        return req as unknown as IDBOpenDBRequest;
      },
    } as unknown as IDBFactory;
    await expect(openHistoryStore("history-fail", failingOpen)).rejects.toThrow("idb open failed");
  });

  it("appendMessage appends and bumps updatedAt, or reports a missing transcript", async () => {
    const store = await openHistoryStore("history-append");
    expect(await appendMessage(store, "t1", turn("late"))).toBe(false);
    await store.putTranscript(transcript());
    expect(await appendMessage(store, "t1", turn("later reply", "assistant"))).toBe(true);
    const updated = await store.getTranscript("t1");
    expect(updated?.messages.length).toBe(3);
    expect(updated?.messages[2]?.text).toBe("later reply");
    expect(updated?.updatedAt).toBe(NOW);
    // A turn older than the transcript's updatedAt must not roll the date back.
    await appendMessage(store, "t1", { role: "user", text: "old", at: NOW - 5 * DAY });
    expect((await store.getTranscript("t1"))?.updatedAt).toBe(NOW);
  });
});

describe("history search", () => {
  it("scores title over url matches and requires every keyword on pages", () => {
    const pages = [
      page(), // title + url match "example": 3 + 1
      page({ id: "p2", title: "Other", url: "https://other.test/example" }), // url only: 1
      page({ id: "p3", title: "Example clone", url: "https://clone.test/" }), // title only: 3
      page({ id: "p4", title: "Unrelated", url: "https://unrelated.test/" }), // no match
    ];
    const hits = searchHistory(pages, [], { keywords: ["example"] }, NOW);
    expect(hits.map((hit) => hit.id)).toEqual([
      "https://example.com/page",
      "https://clone.test/",
      "https://other.test/example",
    ]);
    // title+url = 4, title only = 3, url only = 1; every hit adds the same +2 recency bonus.
    expect(hits[0]?.score).toBe(6);
    expect(hits[1]?.score).toBe(5);
    expect(hits[2]?.score).toBe(3);
    expect(hits[0]?.kind).toBe("page");
  });

  it("scores transcripts by title hits and per-message hits", () => {
    const transcripts = [
      transcript({
        id: "t1",
        messages: [turn("explain rust traits"), turn("traits are like interfaces", "assistant")],
      }),
      transcript({ id: "t2", title: "Unrelated", messages: [turn("cooking pasta")] }),
    ];
    const hits = searchHistory([], transcripts, { keywords: ["rust", "traits"] }, NOW);
    expect(hits.length).toBe(1);
    // "rust": title (3) + first message (2). "traits": two messages (2 + 2). Total
    // 9 before the shared +2 recency bonus.
    expect(hits[0]?.id).toBe("t1");
    expect(hits[0]?.score).toBe(9 + 2);
    expect(hits[0]?.url).toBe("");
    expect(hits[0]?.date).toBe(NOW - 1 * DAY);
  });

  it("applies recency bonus windows deterministically", () => {
    const pages = [
      page({ id: "p1", url: "https://fresh.test/", title: "a", lastVisitTime: NOW - 7 * DAY }),
      page({
        id: "p2",
        url: "https://recent.test/",
        title: "b",
        lastVisitTime: NOW - 7 * DAY - 1,
      }),
      page({
        id: "p3",
        url: "https://stale.test/",
        title: "c",
        lastVisitTime: NOW - 30 * DAY - 1,
      }),
      page({ id: "p4", url: "https://future.test/", title: "d", lastVisitTime: NOW + DAY }),
    ];
    const hits = searchHistory(pages, [], { keywords: [] }, NOW);
    const scores = new Map(hits.map((hit) => [hit.url, hit.score]));
    expect(scores.get("https://fresh.test/")).toBe(2);
    expect(scores.get("https://recent.test/")).toBe(1);
    expect(scores.get("https://stale.test/")).toBe(0);
    // A future timestamp clamps to age 0, which is the fresh window.
    expect(scores.get("https://future.test/")).toBe(2);
  });

  it("filters by inclusive since/until bounds on each dataset's date", () => {
    const pages = [
      page({ id: "p1", lastVisitTime: 100 }),
      page({ id: "p2", url: "https://p2.test/", lastVisitTime: 200 }),
    ];
    const transcripts = [transcript({ id: "t1", updatedAt: 150 })];
    const range: HistoryQuery = { keywords: [], since: 100, until: 200 };
    expect(searchHistory(pages, transcripts, range, NOW).map((hit) => hit.id)).toEqual([
      "https://p2.test/",
      "t1",
      "https://example.com/page",
    ]); // equal dates pass; order is score tie, then newest first
    expect(
      searchHistory(pages, transcripts, { keywords: [], since: 151 }, NOW).map((hit) => hit.id),
    ).toEqual(["https://p2.test/"]);
    expect(
      searchHistory(pages, transcripts, { keywords: [], until: 149 }, NOW).map((hit) => hit.id),
    ).toEqual(["https://example.com/page"]);
  });

  it("matches everything in range when keywords are empty or all blank", () => {
    const pages = [page(), page({ id: "p2", url: "https://other.test/", title: "Other" })];
    const transcripts = [transcript()];
    expect(searchHistory(pages, transcripts, { keywords: [] }, NOW).length).toBe(3);
    expect(searchHistory(pages, transcripts, { keywords: ["  ", ""] }, NOW).length).toBe(3);
  });

  it("orders by score then date and respects the limit", () => {
    const pages = [
      page({ id: "old-hit", url: "https://hit.test/a", title: "same", lastVisitTime: 100 }),
      page({ id: "new-hit", url: "https://hit.test/b", title: "same", lastVisitTime: 200 }),
      page({ id: "big-hit", url: "https://big.test/", title: "same hit", lastVisitTime: 300 }),
    ];
    // All three share the +2 recency bonus (age clamps to 0). big-hit matches both
    // keywords in the title (6); the other two tie at 4 each and order newest first.
    const hits = searchHistory(pages, [], { keywords: ["same", "hit"] }, 0);
    expect(hits.map((hit) => hit.id)).toEqual([
      "https://big.test/",
      "https://hit.test/b",
      "https://hit.test/a",
    ]);
    expect(hits[0]?.score).toBe(8);
    expect(hits[1]?.score).toBe(6);
    expect(searchHistory(pages, [], { keywords: ["same", "hit"], limit: 2 }, 0).length).toBe(2);
    expect(searchHistory(pages, [], { keywords: ["same", "hit"], limit: -1 }, 0)).toEqual([]);
  });

  it("searchStoredHistory loads both datasets from the store", async () => {
    const store = await openHistoryStore("history-search-stored");
    await store.putPage(page());
    await store.putTranscript(transcript());
    const hits = await searchStoredHistory(store, { keywords: ["traits"] });
    expect(hits.length).toBe(1);
    const explicit = await searchStoredHistory(store, { keywords: ["traits"] }, NOW);
    expect(explicit.map((hit) => hit.id)).toEqual(["t1"]);
  });

  it("uses the default limit when the query omits one", () => {
    expect(DEFAULT_SEARCH_LIMIT).toBe(50);
    const pages = Array.from({ length: 60 }, (_, index) =>
      page({ id: `p${index}`, url: `https://${index}.test/`, title: `Site ${index}` }),
    );
    const hits = searchHistory(pages, [], { keywords: ["site"] }, NOW);
    expect(hits.length).toBe(DEFAULT_SEARCH_LIMIT);
  });
});

describe("history protocol", () => {
  const query: HistoryQuery = { keywords: ["x"], since: 0, until: 9, limit: 5 };
  const validMessage = turn("hello");
  const validTranscript = transcript();
  const validPage = page();
  const validHit: SearchHit = {
    kind: "page",
    id: "https://x.test/",
    title: "X",
    url: "https://x.test/",
    date: 3,
    score: 4,
  };

  describe("parseTranscriptMessage", () => {
    it("accepts user and assistant turns and rejects malformed values", () => {
      expect(parseTranscriptMessage(validMessage)).toEqual(validMessage);
      expect(parseTranscriptMessage({ role: "assistant", text: "hi", at: 1 })).toEqual({
        role: "assistant",
        text: "hi",
        at: 1,
      });
      expect(parseTranscriptMessage(null)).toBeNull();
      expect(parseTranscriptMessage(42)).toBeNull();
      expect(parseTranscriptMessage({ role: "system", text: "hi", at: 1 })).toBeNull();
      expect(parseTranscriptMessage({ role: "user", text: 1, at: 1 })).toBeNull();
      expect(parseTranscriptMessage({ role: "user", text: "hi" })).toBeNull();
      expect(parseTranscriptMessage({ role: "user", text: "hi", at: "1" })).toBeNull();
      expect(parseTranscriptMessage({ role: "user", text: "hi", at: Number.NaN })).toBeNull();
      expect(parseTranscriptMessage({ role: "user", text: "hi", at: Number.POSITIVE_INFINITY }))
        .toBeNull();
    });
  });

  describe("parseTranscriptRecord", () => {
    it("accepts a full transcript and rejects malformed values", () => {
      const parsed = parseTranscriptRecord(validTranscript);
      expect(parsed).toEqual(validTranscript);
      // Messages are rebuilt into fresh validated objects, never passed through as-is.
      expect(parsed?.messages).not.toBe(validTranscript.messages);
      expect(parseTranscriptRecord(null)).toBeNull();
      expect(parseTranscriptRecord("t1")).toBeNull();
      expect(parseTranscriptRecord({ ...validTranscript, id: "" })).toBeNull();
      expect(parseTranscriptRecord({ ...validTranscript, id: 1 })).toBeNull();
      expect(parseTranscriptRecord({ ...validTranscript, title: 1 })).toBeNull();
      expect(parseTranscriptRecord({ ...validTranscript, surface: 1 })).toBeNull();
      expect(parseTranscriptRecord({ ...validTranscript, startedAt: "1" })).toBeNull();
      expect(parseTranscriptRecord({ ...validTranscript, updatedAt: "1" })).toBeNull();
      expect(parseTranscriptRecord({ ...validTranscript, messages: "nope" })).toBeNull();
      expect(
        parseTranscriptRecord({ ...validTranscript, messages: [{ role: "bot", text: "x", at: 1 }] }),
      ).toBeNull();
      expect(parseTranscriptRecord({ ...validTranscript, messages: ["hi"] })).toBeNull();
    });
  });

  describe("parsePageRecord", () => {
    it("accepts a chrome.history-style page and rejects malformed values", () => {
      expect(parsePageRecord(validPage)).toEqual(validPage);
      expect(parsePageRecord(null)).toBeNull();
      expect(parsePageRecord(7)).toBeNull();
      expect(parsePageRecord({ ...validPage, id: 1 })).toBeNull();
      expect(parsePageRecord({ ...validPage, url: 1 })).toBeNull();
      expect(parsePageRecord({ ...validPage, title: 1 })).toBeNull();
      expect(parsePageRecord({ ...validPage, lastVisitTime: "1" })).toBeNull();
      expect(parsePageRecord({ ...validPage, visitCount: "1" })).toBeNull();
    });
  });

  describe("parseHistoryQuery", () => {
    it("accepts queries with and without optional bounds and rejects malformed values", () => {
      expect(parseHistoryQuery(query)).toEqual(query);
      expect(parseHistoryQuery({ keywords: [] })).toEqual({
        keywords: [],
        since: undefined,
        until: undefined,
        limit: undefined,
      });
      const parsed = parseHistoryQuery(query);
      expect(parsed?.keywords).not.toBe(query.keywords); // defensive copy
      expect(parseHistoryQuery(null)).toBeNull();
      expect(parseHistoryQuery("x")).toBeNull();
      expect(parseHistoryQuery({ since: 0 })).toBeNull();
      expect(parseHistoryQuery({ keywords: [1] })).toBeNull();
      expect(parseHistoryQuery({ keywords: [], since: "0" })).toBeNull();
      expect(parseHistoryQuery({ keywords: [], until: "9" })).toBeNull();
      expect(parseHistoryQuery({ keywords: [], limit: "5" })).toBeNull();
    });
  });

  describe("parseHistoryRequest", () => {
    it("parses each request type and drops malformed payloads", () => {
      const search: HistoryRequest = { type: "noche:history-search", requestId: 1, query };
      const save: HistoryRequest = {
        type: "noche:history-save-transcript",
        requestId: 2,
        transcript: validTranscript,
      };
      const append: HistoryRequest = {
        type: "noche:history-append-message",
        requestId: 3,
        transcriptId: "t1",
        message: validMessage,
      };
      expect(parseHistoryRequest(search)).toEqual(search);
      expect(parseHistoryRequest(save)).toEqual(save);
      expect(parseHistoryRequest(append)).toEqual(append);
      expect(parseHistoryRequest(null)).toBeNull();
      expect(parseHistoryRequest(42)).toBeNull();
      expect(parseHistoryRequest({ type: "noche:history-search", query })).toBeNull();
      expect(parseHistoryRequest({ type: "noche:history-search", requestId: 1 })).toBeNull();
      expect(parseHistoryRequest({ type: "noche:history-save-transcript", requestId: 1 }))
        .toBeNull();
      expect(
        parseHistoryRequest({ type: "noche:history-append-message", requestId: 1 }),
      ).toBeNull();
      expect(
        parseHistoryRequest({
          type: "noche:history-append-message",
          requestId: 1,
          transcriptId: "t1",
          message: "junk",
        }),
      ).toBeNull();
      expect(
        parseHistoryRequest({
          type: "noche:history-append-message",
          requestId: 1,
          message: validMessage,
        }),
      ).toBeNull();
      expect(parseHistoryRequest({ type: "noche:history-something-else", requestId: 1 }))
        .toBeNull();
    });
  });

  describe("parseHistoryResponse", () => {
    it("parses each response type and drops malformed payloads", () => {
      const result: HistoryResponse = {
        type: "noche:history-search-result",
        requestId: 1,
        hits: [validHit],
      };
      const ok: HistoryResponse = { type: "noche:history-ok", requestId: 2, appended: true };
      const error: HistoryResponse = { type: "noche:history-error", requestId: 3, error: "boom" };
      expect(parseHistoryResponse(result)).toEqual(result);
      expect(parseHistoryResponse(ok)).toEqual(ok);
      expect(parseHistoryResponse(error)).toEqual(error);
      expect(parseHistoryResponse(null)).toBeNull();
      expect(parseHistoryResponse(42)).toBeNull();
      expect(parseHistoryResponse({ type: "noche:history-search-result", hits: [] })).toBeNull();
      expect(
        parseHistoryResponse({ type: "noche:history-search-result", requestId: 1 }),
      ).toBeNull();
      expect(
        parseHistoryResponse({ type: "noche:history-search-result", requestId: 1, hits: [{}] }),
      ).toBeNull();
      expect(parseHistoryResponse({ type: "noche:history-ok", requestId: 1 })).toBeNull();
      expect(
        parseHistoryResponse({ type: "noche:history-ok", requestId: 1, appended: "yes" }),
      ).toBeNull();
      expect(parseHistoryResponse({ type: "noche:history-error", requestId: 1 })).toBeNull();
      expect(
        parseHistoryResponse({ type: "noche:history-unknown", requestId: 1, error: "x" }),
      ).toBeNull();
    });

    it("validates every search hit field", () => {
      const response = (hit: unknown) => ({
        type: "noche:history-search-result",
        requestId: 1,
        hits: [hit],
      });
      expect(parseHistoryResponse(response(validHit))).toEqual({
        type: "noche:history-search-result",
        requestId: 1,
        hits: [validHit],
      });
      expect(parseHistoryResponse(response(null))).toBeNull();
      expect(parseHistoryResponse(response({ ...validHit, kind: "site" }))).toBeNull();
      expect(parseHistoryResponse(response({ ...validHit, id: 1 }))).toBeNull();
      expect(parseHistoryResponse(response({ ...validHit, title: 1 }))).toBeNull();
      expect(parseHistoryResponse(response({ ...validHit, url: 1 }))).toBeNull();
      expect(parseHistoryResponse(response({ ...validHit, date: "1" }))).toBeNull();
      expect(parseHistoryResponse(response({ ...validHit, score: "1" }))).toBeNull();
    });
  });
});
