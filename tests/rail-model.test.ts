import { describe, expect, it } from "vitest";
import { RailModel, type RailSnapshot } from "../src/chat/rail-model";
import type { RailMessage } from "../src/chat/rail-protocol";

function harness() {
  const sent: RailMessage[] = [];
  let changes = 0;
  const model = new RailModel({
    post: (message) => sent.push(message),
    onChange: () => {
      changes += 1;
    },
  });
  return {
    model,
    sent,
    changes: () => changes,
    last: () => sent[sent.length - 1],
  };
}

const openTabRequest = { name: "openTab", args: { url: "https://x.test" } };
const listTabsRequest = { name: "listTabs", args: {} };

function chatEvent(model: RailModel, id: number, event: unknown): void {
  model.onPortMessage({ type: "chat-event", id, event });
}

describe("rail model", () => {
  it("starts empty and idle", () => {
    const h = harness();
    const snap = h.model.snapshot();
    expect(snap.phase).toBe("empty");
    expect(snap.busy).toBe(false);
    expect(snap.turns).toEqual([]);
    expect(snap.consent).toBeNull();
  });

  it("send queues user and assistant turns and posts chat-send", () => {
    const h = harness();
    expect(h.model.send("hello there")).toBe(true);
    const snap = h.model.snapshot();
    expect(snap.phase).toBe("streaming");
    expect(snap.busy).toBe(true);
    expect(snap.turns.map((t) => t.role)).toEqual(["user", "assistant"]);
    expect(snap.turns[0]?.text).toBe("hello there");
    expect(snap.turns[1]?.status).toBe("streaming");
    expect(h.sent).toEqual([{ type: "noche:chat-send", id: 1, text: "hello there" }]);
    expect(h.changes()).toBe(1);
  });

  it("send is a no-op for blank text", () => {
    const h = harness();
    expect(h.model.send("   ")).toBe(false);
    expect(h.sent).toEqual([]);
    expect(h.changes()).toBe(0);
  });

  it("send carries the picker binding only when one is given", () => {
    const h = harness();
    expect(h.model.send("bound", { provider: "p2", model: "z" })).toBe(true);
    expect(h.last()).toMatchObject({
      type: "noche:chat-send",
      id: 1,
      text: "bound",
      binding: { provider: "p2", model: "z" },
    });
    h.model.stop();
    expect(h.model.send("plain")).toBe(true);
    const plain = h.last();
    if (plain?.type !== "noche:chat-send") throw new Error("expected chat-send");
    expect(plain.binding).toBeUndefined();
  });

  it("send is refused while a run is streaming or parked on consent", () => {
    const h = harness();
    h.model.send("first");
    expect(h.model.send("second")).toBe(false);
    h.model.onPortMessage({ type: "consent-request", id: 1, requestId: 1, request: openTabRequest });
    expect(h.model.snapshot().phase).toBe("consent");
    expect(h.model.send("third")).toBe(false);
    expect(h.sent.filter((m) => m.type === "noche:chat-send").length).toBe(1);
  });

  it("streams text events into the assistant turn and settles on done", () => {
    const h = harness();
    h.model.send("q");
    chatEvent(h.model, 1, { type: "text", text: "Hel" });
    chatEvent(h.model, 1, { type: "text", text: "lo" });
    chatEvent(h.model, 1, { type: "done" });
    const snap = h.model.snapshot();
    expect(snap.phase).toBe("idle");
    expect(snap.busy).toBe(false);
    expect(snap.turns[1]?.text).toBe("Hello");
    expect(snap.turns[1]?.status).toBe("done");
  });

  it("drops events for unknown or finished runs and malformed payloads", () => {
    const h = harness();
    h.model.send("q");
    h.model.onPortMessage(null);
    h.model.onPortMessage("chat-event");
    h.model.onPortMessage({ type: "chat-event", id: 1, event: { type: "junk" } });
    chatEvent(h.model, 99, { type: "text", text: "ghost" });
    chatEvent(h.model, 1, { type: "text", text: "real" });
    chatEvent(h.model, 1, { type: "done" });
    chatEvent(h.model, 1, { type: "text", text: "late" });
    expect(h.model.snapshot().turns[1]?.text).toBe("real");
    expect(h.model.snapshot().phase).toBe("idle");
  });

  it("tracks tool requests and matches results by name, first unresolved", () => {
    const h = harness();
    h.model.send("tabs?");
    chatEvent(h.model, 1, { type: "tool-request", request: openTabRequest });
    chatEvent(h.model, 1, { type: "tool-request", request: openTabRequest });
    chatEvent(h.model, 1, { type: "tool-request", request: listTabsRequest });
    // First unresolved openTab gets the first result; listTabs stays open.
    chatEvent(h.model, 1, {
      type: "tool-result",
      request: openTabRequest,
      result: { ok: false, error: "refused: consent-denied" },
    });
    chatEvent(h.model, 1, {
      type: "tool-result",
      request: listTabsRequest,
      result: { ok: true, value: [] },
    });
    const tools = h.model.snapshot().turns[1]?.tools ?? [];
    expect(tools[0]).toEqual({ request: openTabRequest, ok: false, error: "refused: consent-denied" });
    expect(tools[1]).toEqual({ request: openTabRequest });
    expect(tools[2]).toEqual({ request: listTabsRequest, ok: true });
    // A result whose name matches nothing is ignored.
    chatEvent(h.model, 1, {
      type: "tool-result",
      request: { name: "copyText", args: {} },
      result: { ok: true, value: null },
    });
    expect((h.model.snapshot().turns[1]?.tools ?? []).length).toBe(3);
  });

  it("marks the run errored and keeps the message", () => {
    const h = harness();
    h.model.send("q");
    chatEvent(h.model, 1, { type: "text", text: "partial" });
    chatEvent(h.model, 1, { type: "error", message: "HTTP 401" });
    const snap = h.model.snapshot();
    expect(snap.turns[1]?.status).toBe("error");
    expect(snap.turns[1]?.error).toBe("HTTP 401");
    expect(snap.phase).toBe("idle");
  });

  it("round-trips consent: approve replies and resumes the run", () => {
    const h = harness();
    h.model.send("open x");
    h.model.onPortMessage({
      type: "consent-request",
      id: 1,
      requestId: 4,
      request: openTabRequest,
    });
    let snap = h.model.snapshot();
    expect(snap.phase).toBe("consent");
    expect(snap.busy).toBe(true);
    expect(snap.consent).toEqual({ id: 1, requestId: 4, request: openTabRequest });
    h.model.approveConsent();
    snap = h.model.snapshot();
    expect(h.last()).toEqual({
      type: "noche:consent-reply",
      id: 1,
      requestId: 4,
      approve: true,
    });
    expect(snap.consent).toBeNull();
    expect(snap.phase).toBe("streaming");
  });

  it("deny replies false and a reply without a pending prompt is a no-op", () => {
    const h = harness();
    h.model.denyConsent();
    expect(h.sent).toEqual([]);
    h.model.send("q");
    h.model.onPortMessage({ type: "consent-request", id: 1, requestId: 2, request: openTabRequest });
    h.model.denyConsent();
    expect(h.last()).toEqual({
      type: "noche:consent-reply",
      id: 1,
      requestId: 2,
      approve: false,
    });
  });

  it("consent requests for stale runs are dropped", () => {
    const h = harness();
    h.model.onPortMessage({ type: "consent-request", id: 9, requestId: 1, request: openTabRequest });
    expect(h.model.snapshot().consent).toBeNull();
    expect(h.model.snapshot().phase).toBe("empty");
  });

  it("stop aborts the run and marks the streaming turn stopped", () => {
    const h = harness();
    h.model.send("q");
    chatEvent(h.model, 1, { type: "text", text: "so far" });
    h.model.stop();
    expect(h.last()).toEqual({ type: "noche:chat-stop", id: 1 });
    const snap = h.model.snapshot();
    expect(snap.turns[1]?.status).toBe("stopped");
    expect(snap.turns[1]?.text).toBe("so far");
    expect(snap.phase).toBe("idle");
    // A second stop is a no-op: no run is active.
    h.model.stop();
    expect(h.sent.filter((m) => m.type === "noche:chat-stop").length).toBe(1);
  });

  it("stop while parked on consent clears the prompt", () => {
    const h = harness();
    h.model.send("q");
    h.model.onPortMessage({ type: "consent-request", id: 1, requestId: 1, request: openTabRequest });
    h.model.stop();
    const snap = h.model.snapshot();
    expect(snap.consent).toBeNull();
    expect(snap.turns[1]?.status).toBe("stopped");
  });

  it("newChat clears the conversation and refuses mid-run", () => {
    const h = harness();
    h.model.send("q");
    h.model.newChat();
    // Mid-run: ignored, both turns remain and the run continues.
    expect(h.model.snapshot().turns.length).toBe(2);
    expect(h.model.snapshot().phase).toBe("streaming");
    chatEvent(h.model, 1, { type: "done" });
    h.model.newChat();
    const snap = h.model.snapshot();
    expect(snap.turns).toEqual([]);
    expect(snap.phase).toBe("empty");
  });

  it("allocates fresh run ids per send", () => {
    const h = harness();
    h.model.send("one");
    chatEvent(h.model, 1, { type: "done" });
    h.model.send("two");
    expect(h.sent.filter((m) => m.type === "noche:chat-send").map((m) => m.id)).toEqual([1, 2]);
  });

  it("onChange fires once per accepted port message", () => {
    const h = harness();
    h.model.send("q");
    const before = h.changes();
    chatEvent(h.model, 1, { type: "text", text: "x" });
    chatEvent(h.model, 2, { type: "text", text: "dropped" });
    expect(h.changes()).toBe(before + 1);
  });

  it("snapshot shapes stay stable for renderers", () => {
    const h = harness();
    h.model.send("q");
    const snap: RailSnapshot = h.model.snapshot();
    expect(Object.keys(snap).sort()).toEqual(["busy", "consent", "phase", "turns"]);
  });
});
