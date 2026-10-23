import { requestToPromise } from "../context/store";

/**
 * Local chat-history persistence: one IndexedDB database with two object
 * stores, "transcripts" (saved side panel conversations) and "pages"
 * (chrome.history-style visited pages). Everything stays on-device; nothing
 * here ever leaves the browser.
 */

/** One turn of a saved conversation. */
export interface TranscriptMessage {
  role: "user" | "assistant";
  text: string;
  /** Epoch milliseconds when the turn was produced. */
  at: number;
}

/** A saved chat conversation, keyed by id. */
export interface TranscriptRecord {
  id: string;
  /** Display label; conventionally the first user message, trimmed. */
  title: string;
  /** Which surface produced it (e.g. "sidepanel"). */
  surface: string;
  startedAt: number;
  updatedAt: number;
  messages: TranscriptMessage[];
}

/**
 * chrome.history-style page visit, keyed by url. Field names mirror the
 * chrome.history.HistoryItem shape so background imports need no mapping.
 */
export interface PageRecord {
  id: string;
  url: string;
  title: string;
  /** Epoch milliseconds of the most recent visit. */
  lastVisitTime: number;
  visitCount: number;
}

export interface HistoryStore {
  putTranscript(record: TranscriptRecord): Promise<void>;
  getTranscript(id: string): Promise<TranscriptRecord | undefined>;
  deleteTranscript(id: string): Promise<void>;
  allTranscripts(): Promise<TranscriptRecord[]>;
  putPage(record: PageRecord): Promise<void>;
  getPage(url: string): Promise<PageRecord | undefined>;
  deletePage(url: string): Promise<void>;
  allPages(): Promise<PageRecord[]>;
}

/**
 * Thin IndexedDB wrapper: two object stores, no indices, no migrations. Both
 * stores are created together in v1 because search needs both datasets from
 * day one; anything beyond this earns a schema bump.
 */
export function openHistoryStore(
  dbName = "noche-history",
  idb: IDBFactory = indexedDB,
): Promise<HistoryStore> {
  return new Promise((resolve, reject) => {
    const request = idb.open(dbName, 1);
    request.onupgradeneeded = () => {
      request.result.createObjectStore("transcripts", { keyPath: "id" });
      request.result.createObjectStore("pages", { keyPath: "url" });
    };
    request.onsuccess = () => {
      const db = request.result;
      const store = (name: "transcripts" | "pages", mode: IDBTransactionMode) =>
        db.transaction(name, mode).objectStore(name);
      resolve({
        putTranscript: async (record) => {
          await requestToPromise(store("transcripts", "readwrite").put(record));
        },
        getTranscript: (id) =>
          requestToPromise(
            store("transcripts", "readonly").get(id) as IDBRequest<TranscriptRecord | undefined>,
          ),
        deleteTranscript: async (id) => {
          await requestToPromise(store("transcripts", "readwrite").delete(id));
        },
        allTranscripts: () =>
          requestToPromise(
            store("transcripts", "readonly").getAll() as IDBRequest<TranscriptRecord[]>,
          ),
        putPage: async (record) => {
          await requestToPromise(store("pages", "readwrite").put(record));
        },
        getPage: (url) =>
          requestToPromise(store("pages", "readonly").get(url) as IDBRequest<PageRecord | undefined>),
        deletePage: async (url) => {
          await requestToPromise(store("pages", "readwrite").delete(url));
        },
        allPages: () => requestToPromise(store("pages", "readonly").getAll() as IDBRequest<PageRecord[]>),
      });
    };
    request.onerror = () => reject(request.error ?? new Error("idb open failed"));
  });
}

/**
 * Append one turn to a saved transcript and bump its updatedAt. Returns false
 * (and writes nothing) when the transcript does not exist, so a late append
 * for a deleted conversation cannot resurrect it.
 */
export async function appendMessage(
  store: HistoryStore,
  transcriptId: string,
  message: TranscriptMessage,
): Promise<boolean> {
  const transcript = await store.getTranscript(transcriptId);
  if (transcript === undefined) return false;
  await store.putTranscript({
    ...transcript,
    messages: [...transcript.messages, message],
    updatedAt: Math.max(transcript.updatedAt, message.at),
  });
  return true;
}
