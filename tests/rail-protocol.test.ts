import { describe, expect, it } from "vitest";
import {
  CHAT_PORT,
  CONTEXT_REQUEST,
  parseChatEvent,
  parseRailContextResponse,
  parseRailMessage,
  parseRailPortMessage,
  parseRequestObject,
} from "../src/chat/rail-protocol";

const request = { name: "openTab", args: { url: "https://x.test" } };

describe("chat rail wire contract", () => {
  it("names the port and the context request", () => {
    expect(CHAT_PORT).toBe("noche-chat");
    expect(CONTEXT_REQUEST).toBe("noche:get-chat-context");
  });

  describe("parseChatEvent", () => {
    it("accepts every well-formed event kind", () => {
      expect(parseChatEvent({ type: "text", text: "he" })).toEqual({ type: "text", text: "he" });
      expect(parseChatEvent({ type: "tool-request", request })).toEqual({
        type: "tool-request",
        request,
      });
      expect(
        parseChatEvent({ type: "tool-result", request, result: { ok: true, value: 1 } }),
      ).toEqual({ type: "tool-result", request, result: { ok: true, value: 1 } });
      expect(
        parseChatEvent({ type: "tool-result", request, result: { ok: false, error: "no" } }),
      ).toEqual({ type: "tool-result", request, result: { ok: false, error: "no" } });
      expect(parseChatEvent({ type: "done" })).toEqual({ type: "done" });
      expect(parseChatEvent({ type: "error", message: "boom" })).toEqual({
        type: "error",
        message: "boom",
      });
    });

    it("rejects malformed payloads", () => {
      expect(parseChatEvent(null)).toBeNull();
      expect(parseChatEvent("text")).toBeNull();
      expect(parseChatEvent([])).toBeNull();
      expect(parseChatEvent({ type: "text" })).toBeNull();
      expect(parseChatEvent({ type: "text", text: 5 })).toBeNull();
      expect(parseChatEvent({ type: "tool-request", request: "nope" })).toBeNull();
      expect(parseChatEvent({ type: "tool-result", request, result: null })).toBeNull();
      expect(parseChatEvent({ type: "tool-result", request: "nope", result: { ok: true } })).toBeNull();
      expect(parseChatEvent({ type: "tool-result", request, result: { ok: false } })).toBeNull();
      expect(parseChatEvent({ type: "tool-result", request, result: { ok: "yes" } })).toBeNull();
      expect(parseChatEvent({ type: "done", extra: true })).toEqual({ type: "done" });
      expect(parseChatEvent({ type: "error" })).toBeNull();
      expect(parseChatEvent({ type: "mystery" })).toBeNull();
      expect(parseChatEvent(undefined)).toBeNull();
    });
  });

  describe("parseRailPortMessage", () => {
    it("accepts chat events and consent requests", () => {
      expect(parseRailPortMessage({ type: "chat-event", id: 3, event: { type: "done" } })).toEqual({
        type: "noche:chat-event",
        id: 3,
        event: { type: "done" },
      });
      expect(
        parseRailPortMessage({ type: "consent-request", id: 3, requestId: 7, request }),
      ).toEqual({ type: "noche:consent-request", id: 3, requestId: 7, request });
    });

    it("rejects malformed payloads", () => {
      expect(parseRailPortMessage("chat-event")).toBeNull();
      expect(parseRailPortMessage({ type: "chat-event", id: "3", event: { type: "done" } })).toBeNull();
      expect(parseRailPortMessage({ type: "chat-event", id: 3, event: { type: "junk" } })).toBeNull();
      expect(
        parseRailPortMessage({ type: "consent-request", id: 3, request }),
      ).toBeNull();
      expect(
        parseRailPortMessage({ type: "consent-request", id: 3, requestId: 7, request: {} }),
      ).toBeNull();
      expect(parseRailPortMessage({ type: "nope" })).toBeNull();
      expect(parseRailPortMessage(42)).toBeNull();
    });
  });

  describe("parseRailMessage", () => {
    it("accepts send, stop and consent replies", () => {
      expect(parseRailMessage({ type: "chat-send", id: 1, text: "hi" })).toEqual({
        type: "noche:chat-send",
        id: 1,
        text: "hi",
      });
      expect(parseRailMessage({ type: "chat-stop", id: 1 })).toEqual({
        type: "noche:chat-stop",
        id: 1,
      });
      expect(parseRailMessage({ type: "consent-reply", id: 1, requestId: 2, approve: true })).toEqual({
        type: "noche:consent-reply",
        id: 1,
        requestId: 2,
        approve: true,
      });
    });

    it("carries a well-formed send binding and drops malformed ones", () => {
      expect(
        parseRailMessage({ type: "chat-send", id: 1, text: "hi", binding: { provider: "p", model: "m" } }),
      ).toEqual({
        type: "noche:chat-send",
        id: 1,
        text: "hi",
        binding: { provider: "p", model: "m" },
      });
      for (const broken of [
        "text",
        {},
        { provider: "p", model: "" },
        { provider: "", model: "m" },
        { provider: "p" },
      ]) {
        expect(parseRailMessage({ type: "chat-send", id: 1, text: "hi", binding: broken })).toBeNull();
      }
    });

    it("keeps plain sends free of a binding", () => {
      const parsed = parseRailMessage({ type: "chat-send", id: 1, text: "hi" });
      if (parsed?.type !== "noche:chat-send") throw new Error("expected chat-send");
      expect(parsed.binding).toBeUndefined();
    });

    it("rejects malformed payloads", () => {
      expect(parseRailMessage(null)).toBeNull();
      expect(parseRailMessage({ type: "chat-send", id: "1", text: "hi" })).toBeNull();
      expect(parseRailMessage({ type: "chat-send", id: 1 })).toBeNull();
      expect(parseRailMessage({ type: "chat-stop" })).toBeNull();
      expect(parseRailMessage({ type: "chat-stop", id: "1" })).toBeNull();
      expect(parseRailMessage({ type: "consent-reply", id: 1, requestId: 2 })).toBeNull();
      expect(parseRailMessage({ type: "consent-reply", id: 1, requestId: "2", approve: true })).toBeNull();
      expect(parseRailMessage({ type: "consent-reply", id: 1, requestId: 2, approve: "yes" })).toBeNull();
      expect(parseRailMessage({ type: "unknown" })).toBeNull();
    });
  });

  describe("parseRequestObject", () => {
    it("accepts {name, args} objects and rejects the rest", () => {
      expect(parseRequestObject({ name: "openTab", args: {} })).toEqual({ name: "openTab", args: {} });
      expect(parseRequestObject({ name: "x", args: [] })).toBeNull();
      expect(parseRequestObject({ args: {} })).toBeNull();
      expect(parseRequestObject({ name: 7, args: {} })).toBeNull();
      expect(parseRequestObject("openTab")).toBeNull();
      expect(parseRequestObject(null)).toBeNull();
    });
  });

  describe("parseRailContextResponse", () => {
    it("accepts a full snapshot and tolerates a missing chip", () => {
      const full = parseRailContextResponse({
        ok: true,
        context: {
          providerLabel: "Local fleet",
          modelLabel: "North",
          chip: { title: "Example", origin: "https://example.com" },
        },
      });
      expect(full).toEqual({
        ok: true,
        context: {
          providerLabel: "Local fleet",
          modelLabel: "North",
          chip: { title: "Example", origin: "https://example.com" },
        },
      });
      expect(
        parseRailContextResponse({ ok: true, context: { providerLabel: "p", modelLabel: "m" } }),
      ).toEqual({ ok: true, context: { providerLabel: "p", modelLabel: "m", chip: null } });
    });

    it("degrades malformed payloads to errors", () => {
      expect(parseRailContextResponse(undefined)).toEqual({
        ok: false,
        error: "malformed context response",
      });
      expect(parseRailContextResponse({ ok: true, context: null })).toEqual({
        ok: false,
        error: "malformed context payload",
      });
      expect(
        parseRailContextResponse({ ok: true, context: { providerLabel: "p" } }),
      ).toEqual({ ok: false, error: "malformed context payload" });
      expect(
        parseRailContextResponse({ ok: true, context: { providerLabel: 1, modelLabel: "m" } }),
      ).toEqual({ ok: false, error: "malformed context payload" });
      expect(
        parseRailContextResponse({
          ok: true,
          context: { providerLabel: "p", modelLabel: "m", chip: { title: "t" } },
        }),
      ).toEqual({ ok: true, context: { providerLabel: "p", modelLabel: "m", chip: null } });
      expect(parseRailContextResponse({ ok: false })).toEqual({
        ok: false,
        error: "malformed context response",
      });
      expect(parseRailContextResponse({ ok: false, error: "later" })).toEqual({
        ok: false,
        error: "later",
      });
    });
  });
});
