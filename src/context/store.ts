export interface ContextRecord {
  tabId: number;
  origin: string;
  url: string;
  title: string;
  text: string;
  tokens: number;
  extractedAt: number;
}

export interface ContextStore {
  put(record: ContextRecord): Promise<void>;
  get(tabId: number): Promise<ContextRecord | undefined>;
  delete(tabId: number): Promise<void>;
  all(): Promise<ContextRecord[]>;
}

/** Promisify a single IDBRequest (exported because it is the module's one utility). */
export function requestToPromise<T>(req: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error ?? new Error("idb request failed"));
  });
}

/**
 * Thin IndexedDB wrapper: one object store keyed by tabId. Deliberately minimal
 * so the whole thing stays fully branch-testable; a v2 schema bump will bring
 * migration logic when a second store or index earns its bytes.
 */
export function openContextStore(
  dbName = "noche-context",
  idb: IDBFactory = indexedDB,
): Promise<ContextStore> {
  return new Promise((resolve, reject) => {
    const request = idb.open(dbName, 1);
    request.onupgradeneeded = () => {
      request.result.createObjectStore("tabs", { keyPath: "tabId" });
    };
    request.onsuccess = () => {
      const db = request.result;
      const store = (mode: IDBTransactionMode) =>
        db.transaction("tabs", mode).objectStore("tabs");
      resolve({
        put: async (record) => {
          await requestToPromise(store("readwrite").put(record));
        },
        get: (tabId) =>
          requestToPromise(store("readonly").get(tabId) as IDBRequest<ContextRecord | undefined>),
        delete: async (tabId) => {
          await requestToPromise(store("readwrite").delete(tabId));
        },
        all: () => requestToPromise(store("readonly").getAll() as IDBRequest<ContextRecord[]>),
      });
    };
    request.onerror = () => reject(request.error ?? new Error("idb open failed"));
  });
}
