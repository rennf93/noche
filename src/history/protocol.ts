import type { HistoryQuery, SearchHit } from "./search";
import type { PageRecord, TranscriptMessage, TranscriptRecord } from "./store";

/**
 * Message contract for local history access from the side panel: the panel
 * sends a HistoryRequest as a one-shot runtime message and the background
 * answers on the sendResponse channel with a HistoryResponse (mirroring the
 * chat/protocol.ts surface contract). Producers assert with `satisfies`,
 * consumers validate with the parse functions, so malformed or hostile
 * payloads are dropped, never trusted.
 */

/** Panel -> background. */
export type HistoryRequest =
  /** Run a keyword search over transcripts and page records. */
  | { type: "noche:history-search"; requestId: number; query: HistoryQuery }
  /** Save (or replace) a whole transcript. */
  | { type: "noche:history-save-transcript"; requestId: number; transcript: TranscriptRecord }
  /** Append one turn to an already-saved transcript. */
  | {
      type: "noche:history-append-message";
      requestId: number;
      transcriptId: string;
      message: TranscriptMessage;
    };

/** Background -> panel, answered on the sendResponse channel. */
export type HistoryResponse =
  /** Answer to "noche:history-search". */
  | { type: "noche:history-search-result"; requestId: number; hits: SearchHit[] }
  /** Success answer to save/append. */
  | { type: "noche:history-ok"; requestId: number; appended: boolean }
  /** Failure answer to any request; the panel degrades, never throws. */
  | { type: "noche:history-error"; requestId: number; error: string };

/** Structural guard for one transcript turn; null when malformed. */
export function parseTranscriptMessage(value: unknown): TranscriptMessage | null {
  if (typeof value !== "object" || value === null) return null;
  const candidate = value as Partial<TranscriptMessage>;
  if (candidate.role !== "user" && candidate.role !== "assistant") return null;
  if (typeof candidate.text !== "string") return null;
  if (typeof candidate.at !== "number" || !Number.isFinite(candidate.at)) return null;
  return { role: candidate.role, text: candidate.text, at: candidate.at };
}

/** Structural guard for a whole transcript; null when malformed. */
export function parseTranscriptRecord(value: unknown): TranscriptRecord | null {
  if (typeof value !== "object" || value === null) return null;
  const candidate = value as Partial<TranscriptRecord>;
  if (typeof candidate.id !== "string" || candidate.id === "") return null;
  if (typeof candidate.title !== "string") return null;
  if (typeof candidate.surface !== "string") return null;
  if (typeof candidate.startedAt !== "number") return null;
  if (typeof candidate.updatedAt !== "number") return null;
  if (!Array.isArray(candidate.messages)) return null;
  const messages: TranscriptMessage[] = [];
  for (const message of candidate.messages) {
    const parsed = parseTranscriptMessage(message);
    if (parsed === null) return null;
    messages.push(parsed);
  }
  return {
    id: candidate.id,
    title: candidate.title,
    surface: candidate.surface,
    startedAt: candidate.startedAt,
    updatedAt: candidate.updatedAt,
    messages,
  };
}

/** Structural guard for a page record off the wire; null when malformed. */
export function parsePageRecord(value: unknown): PageRecord | null {
  if (typeof value !== "object" || value === null) return null;
  const candidate = value as Partial<PageRecord>;
  if (typeof candidate.id !== "string") return null;
  if (typeof candidate.url !== "string") return null;
  if (typeof candidate.title !== "string") return null;
  if (typeof candidate.lastVisitTime !== "number") return null;
  if (typeof candidate.visitCount !== "number") return null;
  return {
    id: candidate.id,
    url: candidate.url,
    title: candidate.title,
    lastVisitTime: candidate.lastVisitTime,
    visitCount: candidate.visitCount,
  };
}

/** Validate a search query off the wire; null when malformed. */
export function parseHistoryQuery(value: unknown): HistoryQuery | null {
  if (typeof value !== "object" || value === null) return null;
  const candidate = value as Partial<HistoryQuery>;
  if (!Array.isArray(candidate.keywords)) return null;
  for (const keyword of candidate.keywords) {
    if (typeof keyword !== "string") return null;
  }
  if (candidate.since !== undefined && typeof candidate.since !== "number") return null;
  if (candidate.until !== undefined && typeof candidate.until !== "number") return null;
  if (candidate.limit !== undefined && typeof candidate.limit !== "number") return null;
  return {
    keywords: [...candidate.keywords],
    since: candidate.since,
    until: candidate.until,
    limit: candidate.limit,
  };
}

function isSearchHit(value: unknown): value is SearchHit {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value as Partial<SearchHit>;
  return (
    (candidate.kind === "page" || candidate.kind === "transcript") &&
    typeof candidate.id === "string" &&
    typeof candidate.title === "string" &&
    typeof candidate.url === "string" &&
    typeof candidate.date === "number" &&
    typeof candidate.score === "number"
  );
}

/** Validate one panel request; null for anything foreign or malformed. */
export function parseHistoryRequest(value: unknown): HistoryRequest | null {
  if (typeof value !== "object" || value === null) return null;
  const raw = value as Record<string, unknown>;
  if (typeof raw.requestId !== "number") return null;
  switch (raw.type) {
    case "noche:history-search": {
      const query = parseHistoryQuery(raw.query);
      return query === null
        ? null
        : { type: "noche:history-search", requestId: raw.requestId, query };
    }
    case "noche:history-save-transcript": {
      const transcript = parseTranscriptRecord(raw.transcript);
      return transcript === null
        ? null
        : { type: "noche:history-save-transcript", requestId: raw.requestId, transcript };
    }
    case "noche:history-append-message": {
      if (typeof raw.transcriptId !== "string") return null;
      const message = parseTranscriptMessage(raw.message);
      return message === null
        ? null
        : {
            type: "noche:history-append-message",
            requestId: raw.requestId,
            transcriptId: raw.transcriptId,
            message,
          };
    }
    default:
      return null;
  }
}

/** Validate one background response; null for anything foreign or malformed. */
export function parseHistoryResponse(value: unknown): HistoryResponse | null {
  if (typeof value !== "object" || value === null) return null;
  const raw = value as Record<string, unknown>;
  if (typeof raw.requestId !== "number") return null;
  switch (raw.type) {
    case "noche:history-search-result": {
      if (!Array.isArray(raw.hits)) return null;
      const hits: SearchHit[] = [];
      for (const hit of raw.hits) {
        if (!isSearchHit(hit)) return null;
        hits.push(hit);
      }
      return { type: "noche:history-search-result", requestId: raw.requestId, hits };
    }
    case "noche:history-ok":
      return typeof raw.appended === "boolean"
        ? { type: "noche:history-ok", requestId: raw.requestId, appended: raw.appended }
        : null;
    case "noche:history-error":
      return typeof raw.error === "string"
        ? { type: "noche:history-error", requestId: raw.requestId, error: raw.error }
        : null;
    default:
      return null;
  }
}
