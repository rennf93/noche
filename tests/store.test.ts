import "fake-indexeddb/auto";
import { describe, expect, it } from "vitest";
import { openContextStore, requestToPromise, type ContextRecord } from "../src/context/store";

const record = (tabId: number, origin = "https://example.com"): ContextRecord => ({
  tabId,
  origin,
  url: `${origin}/x`,
  title: `Tab ${tabId}`,
  text: "some text",
  tokens: 3,
  extractedAt: 1,
});

describe("context store", () => {
  it("puts, gets, deletes and lists records", async () => {
    const store = await openContextStore("store-basic");
    await store.put(record(1));
    await store.put(record(2, "https://other.test"));
    expect((await store.get(1))?.origin).toBe("https://example.com");
    expect((await store.get(99))).toBeUndefined();
    expect((await store.all()).length).toBe(2);
    await store.delete(1);
    expect((await store.all()).length).toBe(1);
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
    await expect(openContextStore("store-fail", failingOpen)).rejects.toThrow("idb open failed");
  });

  it("requestToPromise resolves on success and rejects on error", async () => {
    const ok: Record<string, unknown> = { result: 7 };
    const okPromise = requestToPromise(ok as unknown as IDBRequest<number>);
    (ok.onsuccess as () => void)();
    await expect(okPromise).resolves.toBe(7);
    const bad: Record<string, unknown> = {};
    const badPromise = requestToPromise(bad as unknown as IDBRequest<number>);
    (bad.onerror as () => void)();
    await expect(badPromise).rejects.toThrow("idb request failed");
  });
});
