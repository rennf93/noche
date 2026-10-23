import { wrapUntrusted } from "../security/markup";
import type { StorageArea } from "../settings/store";

/**
 * The message contract between Noche's surfaces (new tab, side panel, content
 * script) and the background worker. Every wire message is a member of
 * NocheMessage: producers assert with `satisfies`, consumers validate with
 * parseSurfaceMessage, so a malformed or hostile payload can never be trusted
 * blindly by a receiver.
 *
 * Responses ride the same sendResponse channel as plain values: the
 * "noche:extract-page" request answers with an ExtractedPage (context/extract.ts);
 * every other request answers with a NocheMessage.
 */

/** A question queued for the chat surface, waiting for the panel to open. */
export interface PendingQuestion {
  /** Full composer text; the selection is already fenced as untrusted. */
  text: string;
  /** Page origin the selection came from; also labels the untrusted block. */
  origin: string;
  /** The raw trimmed selected text, kept for context chips and display. */
  selection: string;
  /** Epoch milliseconds when the ask was captured. */
  createdAt: number;
}

export type NocheMessage =
  /** Content script: extract the page's readable text (see context/extract.ts). */
  | { type: "noche:extract-page" }
  /** Content script: capture the live text selection, if any. */
  | { type: "noche:get-selection" }
  /** Content script answer to "noche:get-selection" (empty text means none). */
  | { type: "noche:selection-response"; text: string }
  /** Background push (or "noche:take-pending-question" answer; null = none). */
  | { type: "noche:pending-question"; question: PendingQuestion | null }
  /** Side panel on open: read-and-clear the queued question. */
  | { type: "noche:take-pending-question" };

/** Structural guard: only a fully-shaped PendingQuestion crosses surfaces. */
export function isPendingQuestion(value: unknown): value is PendingQuestion {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value as Partial<PendingQuestion>;
  return (
    typeof candidate.text === "string" &&
    candidate.text !== "" &&
    typeof candidate.origin === "string" &&
    candidate.origin !== "" &&
    typeof candidate.selection === "string" &&
    typeof candidate.createdAt === "number" &&
    Number.isFinite(candidate.createdAt)
  );
}

/**
 * Validate an untyped wire value into a NocheMessage. Returns null for anything
 * foreign or malformed; receivers switch on the parsed discriminant only.
 */
export function parseSurfaceMessage(value: unknown): NocheMessage | null {
  if (typeof value !== "object" || value === null) return null;
  const type = (value as { type?: unknown }).type;
  switch (type) {
    case "noche:extract-page":
    case "noche:get-selection":
    case "noche:take-pending-question":
      return { type };
    case "noche:selection-response": {
      const text = (value as { text?: unknown }).text;
      return typeof text === "string" ? { type, text } : null;
    }
    case "noche:pending-question": {
      const question = (value as { question?: unknown }).question;
      return question === null || isPendingQuestion(question) ? { type, question } : null;
    }
    default:
      return null;
  }
}

/**
 * The live selection out of a content-script answer. Null when the answer is
 * not a valid selection response or the selection is blank, so callers fall
 * back to the menu's own selectionText instead of trusting junk from a page.
 */
export function selectionFromResponse(value: unknown): string | null {
  const parsed = parseSurfaceMessage(value);
  if (parsed?.type !== "noche:selection-response") return null;
  const trimmed = parsed.text.trim();
  return trimmed === "" ? null : trimmed;
}

/** Page origin from a URL; opaque (about:blank) or invalid URLs give "unknown". */
export function originOf(url: string): string {
  try {
    const origin = new URL(url).origin;
    return origin === "null" ? "unknown" : origin;
  } catch {
    return "unknown";
  }
}

/** Selections larger than this are truncated before they enter a prompt. */
export const MAX_SELECTION_CHARS = 4000;
export const TRUNCATION_MARKER = "\n[selection truncated]";

/**
 * The prefilled composer question for an "Ask Noche about selection" click.
 * The selection travels inside the untrusted-content sentinel (the injection
 * firewall's choke point), so it is page data from the very first hop. Blank
 * selections produce no question at all.
 */
export function buildSelectionPrompt(origin: string, selection: string): string | null {
  const trimmed = selection.trim();
  if (trimmed === "") return null;
  const clipped =
    trimmed.length > MAX_SELECTION_CHARS
      ? trimmed.slice(0, MAX_SELECTION_CHARS) + TRUNCATION_MARKER
      : trimmed;
  return `What is this selection from ${origin} about?\n\n${wrapUntrusted(origin, clipped)}`;
}

/** PendingQuestion factory; null when there is no question worth queueing. */
export function makePendingQuestion(origin: string, selection: string): PendingQuestion | null {
  const text = buildSelectionPrompt(origin, selection);
  if (text === null) return null;
  return { text, origin, selection: selection.trim(), createdAt: Date.now() };
}

/** chrome.storage.session key holding the queued question (worker-restart safe). */
export const PENDING_QUESTION_KEY = "pendingQuestion";

export async function storePendingQuestion(
  area: StorageArea,
  question: PendingQuestion,
): Promise<void> {
  await area.set(PENDING_QUESTION_KEY, question);
}

/**
 * Read-and-clear: the queued question is delivered exactly once, whether the
 * panel was open (broadcast path) or opens after the click (this path). Any
 * corrupted stored value is discarded, never surfaced to a chat.
 */
export async function takePendingQuestion(area: StorageArea): Promise<PendingQuestion | null> {
  const raw = await area.get(PENDING_QUESTION_KEY);
  await area.set(PENDING_QUESTION_KEY, null);
  return isPendingQuestion(raw) ? raw : null;
}
