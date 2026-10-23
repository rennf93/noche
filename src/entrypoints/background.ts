/// <reference types="chrome" />
import { openContextStore, type ContextStore } from "../context/store";
import type { ExtractedPage } from "../context/extract";
import { runChat, type OrchestratorTab } from "../chat/orchestrator";
import type { ToolAdapters } from "../chat/tools";
import {
  CONTEXT_REQUEST,
  CHAT_PORT,
  parseRailMessage,
  type RailContextResponse,
  type RailMessage,
  type SendBinding,
} from "../chat/rail-protocol";
import { resolveBinding, applySelection, pickerFleet } from "../chat/picker-model";
import {
  PICKER_REQUEST,
  PICKER_SET,
  SKILLS_REQUEST,
  parsePickerSetMessage,
} from "../chat/picker-protocol";
import { toSuggestion } from "../skills/registry";
import { collectSkills } from "../skills/collect";
import {
  makePendingQuestion,
  originOf,
  parseSurfaceMessage,
  selectionFromResponse,
  storePendingQuestion,
  takePendingQuestion,
  type NocheMessage,
} from "../chat/protocol";
import { resolveModel } from "../providers";
import { LOCAL_FLEET_KEY, activeProvider, loadSettings, saveSettings, type NocheSettings } from "../settings/store";
import type { StorageArea } from "../settings/store";

/** The one context-menu item this surface owns. */
const MENU_ID = "noche-ask-selection";

/**
 * Background wiring, two halves:
 *
 * 1. Ask-about-selection: a "selection" context-menu item captures the live
 *    selection from the page's content script, queues it as a pending
 *    question (selection fenced untrusted by chat/protocol), and opens the
 *    side panel, which pulls the question via the take-pending-question
 *    handshake. chrome (not browser) is used for sidePanel because the
 *    namespace is Chrome-only and absent from webextension-polyfill's Browser
 *    type.
 *
 * 2. The chat rail's engine: one long-lived port per open panel hosts
 *    runChat with adapters over the real chrome APIs, streams events back,
 *    round-trips write-tool consent prompts, and aborts the provider stream
 *    on stop. A one-shot runtime message ("noche:get-chat-context") delivers
 *    the model badge and the active tab's context chip.
 */

/** Minimal structural view of the chat port (keeps helpers polyfill-agnostic). */
interface ChatPort {
  postMessage(message: unknown): void;
  onMessage: { addListener(listener: (raw: unknown) => void): void };
  onDisconnect: { addListener(listener: () => void): void };
}

/** One in-flight chat run: its abort controller and parked consent prompts. */
interface ActiveRun {
  controller: AbortController;
  consent: Map<number, (approve: boolean) => void>;
  nextRequestId: number;
}

/** ExtractedPage off the content script; null unless every field is shaped. */
function isExtractedPage(value: unknown): value is ExtractedPage {
  if (typeof value !== "object" || value === null) return false;
  const page = value as Partial<ExtractedPage>;
  return (
    typeof page.origin === "string" &&
    typeof page.url === "string" &&
    typeof page.title === "string" &&
    typeof page.text === "string" &&
    typeof page.tokens === "number"
  );
}

/** Adapters over the real chrome APIs for the tool registry's read/writes. */
function chromeAdapters(): ToolAdapters {
  return {
    listTabs: async () =>
      (await browser.tabs.query({})).map((tab) => ({
        id: tab.id ?? -1,
        title: tab.title ?? "",
        url: tab.url ?? "",
      })),
    openTab: async (url) => {
      await browser.tabs.create({ url });
    },
    closeTab: async (tabId) => {
      await browser.tabs.remove(tabId);
    },
    copyText: async (text) => {
      await navigator.clipboard.writeText(text);
    },
  };
}

export default defineBackground(() => {
  // Session storage: the queued question survives service-worker restarts but
  // never persists past the browser session.
  const session: StorageArea = {
    get: async (key) => (await browser.storage.session.get(key))[key],
    set: async (key, value) => {
      await browser.storage.session.set({ [key]: value });
    },
  };

  // Local storage behind the same single-key shape the settings store expects.
  const local: StorageArea = {
    get: async (key) => (await browser.storage.local.get(key))[key],
    set: async (key, value) => {
      await browser.storage.local.set({ [key]: value });
    },
  };

  // Tab-context store: one IDB object store keyed by tabId, opened lazily so
  // worker startup stays instant.
  let storePromise: Promise<ContextStore> | null = null;
  const store = (): Promise<ContextStore> => (storePromise ??= openContextStore());

  /** The focused window's active tab, when it has an id and URL. */
  async function activeTab(): Promise<{ id: number; title: string; url: string } | null> {
    const [tab] = await browser.tabs.query({ active: true, lastFocusedWindow: true });
    if (tab?.id === undefined || tab.url === undefined || tab.url === "") return null;
    return { id: tab.id, title: tab.title ?? "", url: tab.url };
  }

  /**
   * Fresh extraction of the active tab via the content script, cached in the
   * IDB store. Falls back to the cached record when the tab has no listener
   * (chrome:// pages, discarded tabs). Null tab id means nothing to attach.
   */
  async function extractActiveTab(): Promise<{
    tabId: number | null;
    page: ExtractedPage | null;
    cached: ExtractedPage | null;
  }> {
    const tab = await activeTab();
    if (tab === null) return { tabId: null, page: null, cached: null };
    try {
      const raw: unknown = await browser.tabs.sendMessage(tab.id, {
        type: "noche:extract-page",
      } satisfies NocheMessage);
      if (isExtractedPage(raw)) {
        await store().then((s) => s.put({ tabId: tab.id, ...raw, extractedAt: Date.now() }));
        return { tabId: tab.id, page: raw, cached: raw };
      }
    } catch {
      // No content script here; fall through to the cached extraction.
    }
    const cached = (await (await store()).get(tab.id)) ?? null;
    return { tabId: tab.id, page: null, cached };
  }

  /** The context snapshot behind the rail's model badge and tab chip. */
  async function chatContext(): Promise<RailContextResponse> {
    try {
      const settings: NocheSettings = await loadSettings(local);
      const provider = activeProvider(settings);
      const model = resolveModel(provider, settings.activeModelId);
      const { cached } = await extractActiveTab();
      return {
        ok: true,
        context: {
          providerLabel: provider.label,
          modelLabel: model.label ?? model.id,
          chip: cached === null ? null : { title: cached.title, origin: cached.origin },
        },
      };
    } catch (err) {
      return { ok: false, error: err instanceof Error ? err.message : String(err) };
    }
  }

  /**
   * Start (or no-op a duplicate of) a chat run bound to one rail message id.
   * The optional binding is the panel picker's per-conversation override
   * (chat/picker-model.ts); without it the run binds to stored settings.
   */
  async function startRun(
    runs: Map<number, ActiveRun>,
    port: ChatPort,
    id: number,
    text: string,
    binding?: SendBinding,
  ): Promise<void> {
    if (runs.has(id)) return;
    const run: ActiveRun = { controller: new AbortController(), consent: new Map(), nextRequestId: 0 };
    runs.set(id, run);
    const post = (message: unknown): void => {
      try {
        port.postMessage(message);
      } catch {
        // The panel closed mid-run; onDisconnect has already stopped it.
      }
    };
    try {
      const settings = await loadSettings(local);
      const resolved = resolveBinding(settings, binding ?? null);
      const provider = resolved.config;
      const { tabId, page, cached } = await extractActiveTab();
      const extraction = page ?? cached;
      const tabs: OrchestratorTab[] =
        extraction === null || tabId === null
          ? []
          : [
              {
                tabId,
                origin: extraction.origin,
                text: extraction.text,
                tokens: extraction.tokens,
                active: true,
              },
            ];
      await runChat({
        config: provider,
        apiKey: provider.auth.type === "apiKey" ? LOCAL_FLEET_KEY : undefined,
        modelId: resolved.modelId,
        userMessage: text,
        tabs,
        adapters: chromeAdapters(),
        signal: run.controller.signal,
        consent: (request) =>
          new Promise<boolean>((resolve) => {
            const requestId = run.nextRequestId++;
            run.consent.set(requestId, resolve);
            post({ type: "noche:consent-request", id, requestId, request });
          }),
        onEvent: (event) => post({ type: "noche:chat-event", id, event }),
      });
    } catch (err) {
      post({
        type: "noche:chat-event",
        id,
        event: { type: "error", message: err instanceof Error ? err.message : String(err) },
      });
    } finally {
      if (runs.get(id) === run) runs.delete(id);
    }
  }

  /** Port lifecycle for one open panel: sends, stops, consent replies. */
  function attachChatPort(port: ChatPort): void {
    const runs = new Map<number, ActiveRun>();
    const stopRun = (id: number): void => {
      const run = runs.get(id);
      if (run === undefined) return;
      runs.delete(id);
      for (const resolve of run.consent.values()) resolve(false);
      run.consent.clear();
      run.controller.abort();
    };
    port.onMessage.addListener((raw: unknown) => {
      const message: RailMessage | null = parseRailMessage(raw);
      if (message === null) return;
      if (message.type === "noche:chat-stop") {
        stopRun(message.id);
        return;
      }
      if (message.type === "noche:consent-reply") {
        const resolve = runs.get(message.id)?.consent.get(message.requestId);
        if (resolve === undefined) return;
        runs.get(message.id)?.consent.delete(message.requestId);
        resolve(message.approve);
        return;
      }
      void startRun(runs, port, message.id, message.text, message.binding);
    });
    port.onDisconnect.addListener(() => {
      for (const id of [...runs.keys()]) stopRun(id);
    });
  }

  browser.runtime.onInstalled.addListener(() => {
    browser.contextMenus.create({
      id: MENU_ID,
      title: "Ask Noche about selection",
      contexts: ["selection"],
    });
  });

  browser.contextMenus.onClicked.addListener((info, tab) => {
    if (info.menuItemId !== MENU_ID || tab?.id === undefined) return;
    const tabId = tab.id;
    void (async () => {
      // The content script owns the live selection; the menu's own
      // selectionText is the fallback for pages without a listener
      // (chrome://, PDF viewer, discarded tabs).
      let selection: string | null = null;
      try {
        const response: unknown = await browser.tabs.sendMessage(tabId, {
          type: "noche:get-selection",
        } satisfies NocheMessage);
        selection = selectionFromResponse(response);
      } catch {
        selection = null;
      }
      if (selection === null && typeof info.selectionText === "string") {
        selection = info.selectionText;
      }
      const question = makePendingQuestion(originOf(tab.url ?? ""), selection ?? "");
      if (question === null) return;
      await storePendingQuestion(session, question);
      try {
        await chrome.sidePanel.open({ tabId });
      } catch {
        // Chromes without a configurable side panel: the queued question still
        // pre-fills the panel the next time it opens.
      }
      // An already-open panel prefills live; nobody listening is not an error.
      await browser.runtime
        .sendMessage({ type: "noche:pending-question", question } satisfies NocheMessage)
        .catch(() => undefined);
    })();
  });

  /** Error text for a picker/skills answer; never leaks non-string junk. */
  function errorText(err: unknown): string {
    return err instanceof Error ? err.message : String(err);
  }

  /** One async listener answers every runtime message: the polyfill sends the
   * FIRST resolved value and closes the channel, so a second competing
   * listener could never win. Unknown types resolve undefined (senders never
   * hang, nothing is trusted blindly). */
  browser.runtime.onMessage.addListener(async (message: unknown): Promise<unknown> => {
    const surface = parseSurfaceMessage(message);
    if (surface?.type === "noche:take-pending-question") {
      const question = await takePendingQuestion(session);
      return { type: "noche:pending-question", question } satisfies NocheMessage;
    }
    if (
      typeof message === "object" &&
      message !== null &&
      (message as { type?: unknown }).type === CONTEXT_REQUEST
    ) {
      return chatContext();
    }
    if (
      typeof message === "object" &&
      message !== null &&
      (message as { type?: unknown }).type === PICKER_REQUEST
    ) {
      try {
        return { ok: true, fleet: pickerFleet(await loadSettings(local)) };
      } catch (err) {
        return { ok: false, error: errorText(err) };
      }
    }
    const pickerSet = parsePickerSetMessage(message);
    if (pickerSet !== null) {
      try {
        const settings = await loadSettings(local);
        const updated = applySelection(settings, pickerSet.providerId, pickerSet.modelId);
        if (updated === null) return { ok: false, error: "unknown provider or model" };
        await saveSettings(local, updated);
        return { ok: true, fleet: pickerFleet(updated) };
      } catch (err) {
        return { ok: false, error: errorText(err) };
      }
    }
    if (
      typeof message === "object" &&
      message !== null &&
      (message as { type?: unknown }).type === SKILLS_REQUEST
    ) {
      try {
        const collected = await collectSkills(local);
        return { ok: true, skills: collected.skills.map(toSuggestion) };
      } catch (err) {
        return { ok: false, error: errorText(err) };
      }
    }
    return undefined;
  });

  browser.runtime.onConnect.addListener((port) => {
    if (port.name !== CHAT_PORT) return;
    attachChatPort(port);
  });
});
