import type { ToolRequest } from "../security/interpreter";
import type { ChatEvent } from "./orchestrator";

/**
 * Wire contract for the side panel chat rail (this file is the rail's half of
 * chat/protocol.ts' surface contract: chat traffic is high-frequency, so it
 * rides a dedicated long-lived port instead of one-shot runtime messages).
 * Every cross-context payload is parsed, never cast: malformed messages are
 * dropped, never trusted.
 */

/** Name of the long-lived port the rail opens on startup. */
export const CHAT_PORT = "noche-chat";

/** Type of the one-shot runtime message asking the background for rail context. */
export const CONTEXT_REQUEST = "noche:get-chat-context";

/** Rail -> background, over the chat port. */
export type RailMessage =
  | { type: "noche:chat-send"; id: number; text: string; binding?: SendBinding }
  | { type: "noche:chat-stop"; id: number }
  | { type: "noche:consent-reply"; id: number; requestId: number; approve: boolean };

/**
 * The provider/model a send binds its run to (the picker's per-conversation
 * override, chat/picker-model.ts). Absent sends bind to stored settings.
 */
export interface SendBinding {
  provider: string;
  model: string;
}

/** Background -> rail, over the chat port. */
export type RailPortMessage =
  | { type: "noche:chat-event"; id: number; event: ChatEvent }
  | { type: "noche:consent-request"; id: number; requestId: number; request: ToolRequest };

/** The page context chip: what the rail pins above the composer. */
export interface TabChip {
  title: string;
  origin: string;
}

/** Context snapshot the rail loads once per open (model badge + tab chip). */
export interface RailContext {
  providerLabel: string;
  modelLabel: string;
  chip: TabChip | null;
}

export type RailContextResponse =
  | { ok: true; context: RailContext }
  | { ok: false; error: string };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * Validate an already-parsed tool request object off the port (same shape
 * rules as the interpreter's fence parser, but for a structured-clone value
 * instead of JSON text). Null when malformed.
 */
export function parseRequestObject(raw: unknown): ToolRequest | null {
  if (!isRecord(raw)) return null;
  if (typeof raw.name !== "string") return null;
  if (!isRecord(raw.args)) return null;
  return { name: raw.name, args: raw.args };
}

/** Validate one orchestrator event off the port; null when malformed. */
export function parseChatEvent(raw: unknown): ChatEvent | null {
  if (!isRecord(raw)) return null;
  switch (raw.type) {
    case "text":
      return typeof raw.text === "string" ? { type: "text", text: raw.text } : null;
    case "tool-request": {
      const request = parseRequestObject(raw.request);
      return request === null ? null : { type: "tool-request", request };
    }
    case "tool-result": {
      const request = parseRequestObject(raw.request);
      if (request === null || !isRecord(raw.result)) return null;
      if (raw.result.ok === true) {
        return { type: "tool-result", request, result: { ok: true, value: raw.result.value } };
      }
      if (raw.result.ok === false && typeof raw.result.error === "string") {
        return { type: "tool-result", request, result: { ok: false, error: raw.result.error } };
      }
      return null;
    }
    case "done":
      return { type: "done" };
    case "error":
      return typeof raw.message === "string" ? { type: "error", message: raw.message } : null;
    default:
      return null;
  }
}

/** Validate one background-to-rail port message; null when malformed. */
export function parseRailPortMessage(raw: unknown): RailPortMessage | null {
  if (!isRecord(raw)) return null;
  if (raw.type === "chat-event") {
    if (typeof raw.id !== "number") return null;
    const event = parseChatEvent(raw.event);
    return event === null ? null : { type: "noche:chat-event", id: raw.id, event };
  }
  if (raw.type === "consent-request") {
    if (typeof raw.id !== "number" || typeof raw.requestId !== "number") return null;
    const request = parseRequestObject(raw.request);
    return request === null
      ? null
      : { type: "noche:consent-request", id: raw.id, requestId: raw.requestId, request };
  }
  return null;
}

/** Validate a send binding off the port; null when malformed. */
export function parseSendBinding(raw: unknown): SendBinding | null {
  if (!isRecord(raw)) return null;
  if (typeof raw.provider !== "string" || raw.provider === "") return null;
  if (typeof raw.model !== "string" || raw.model === "") return null;
  return { provider: raw.provider, model: raw.model };
}

/** Validate one rail-to-background port message; null when malformed. */
export function parseRailMessage(raw: unknown): RailMessage | null {
  if (!isRecord(raw)) return null;
  if (raw.type === "chat-send") {
    if (typeof raw.id !== "number" || typeof raw.text !== "string") return null;
    let binding: SendBinding | undefined;
    if (raw.binding !== undefined) {
      const parsed = parseSendBinding(raw.binding);
      if (parsed === null) return null;
      binding = parsed;
    }
    return { type: "noche:chat-send", id: raw.id, text: raw.text, binding };
  }
  if (raw.type === "chat-stop") {
    return typeof raw.id === "number" ? { type: "noche:chat-stop", id: raw.id } : null;
  }
  if (raw.type === "consent-reply") {
    if (
      typeof raw.id !== "number" ||
      typeof raw.requestId !== "number" ||
      typeof raw.approve !== "boolean"
    ) {
      return null;
    }
    return {
      type: "noche:consent-reply",
      id: raw.id,
      requestId: raw.requestId,
      approve: raw.approve,
    };
  }
  return null;
}

/** Validate the context response; malformed payloads degrade to an error. */
export function parseRailContextResponse(raw: unknown): RailContextResponse {
  if (!isRecord(raw)) return { ok: false, error: "malformed context response" };
  if (raw.ok === true) {
    const context = raw.context;
    if (
      !isRecord(context) ||
      typeof context.providerLabel !== "string" ||
      typeof context.modelLabel !== "string"
    ) {
      return { ok: false, error: "malformed context payload" };
    }
    let chip: TabChip | null = null;
    if (
      isRecord(context.chip) &&
      typeof context.chip.title === "string" &&
      typeof context.chip.origin === "string"
    ) {
      chip = { title: context.chip.title, origin: context.chip.origin };
    }
    return {
      ok: true,
      context: { providerLabel: context.providerLabel, modelLabel: context.modelLabel, chip },
    };
  }
  if (raw.ok === false && typeof raw.error === "string") return { ok: false, error: raw.error };
  return { ok: false, error: "malformed context response" };
}
