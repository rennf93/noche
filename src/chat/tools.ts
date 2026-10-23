import { z } from "zod";
import type { ToolRequest } from "../security/interpreter";
import type { ToolSpec } from "../security/gate";

/**
 * Tool registry for chat-driven tab actions. Schemas validate model-supplied
 * args before anything runs; execution goes through ToolAdapters so the chat
 * layer needs no browser APIs and tests inject stubs. Chrome glue implements
 * ToolAdapters in the entrypoint layer.
 */
export interface TabInfo {
  id: number;
  title: string;
  url: string;
}

export interface ToolAdapters {
  listTabs(): Promise<TabInfo[]>;
  openTab(url: string): Promise<void>;
  closeTab(tabId: number): Promise<void>;
  copyText(text: string): Promise<void>;
}

const listTabsArgs = z.object({}).strict();
const openTabArgs = z.object({ url: z.string().url() }).strict();
const closeTabArgs = z.object({ tabId: z.number().int() }).strict();
const copyTextArgs = z.object({ text: z.string() }).strict();

export interface ToolDefinition<A = unknown> {
  spec: ToolSpec;
  argsSchema: z.ZodType<A>;
  run(adapters: ToolAdapters, args: A): Promise<unknown>;
}

export const toolRegistry: Record<string, ToolDefinition<any>> = {
  listTabs: {
    spec: {
      name: "listTabs",
      kind: "read",
      description: "List open tabs with id, title and url. args: {}. Read: no consent needed.",
    },
    argsSchema: listTabsArgs,
    run: (adapters) => adapters.listTabs(),
  },
  openTab: {
    spec: {
      name: "openTab",
      kind: "write",
      description: "Open a URL in a new tab. args: {url}. Write: needs user consent.",
    },
    argsSchema: openTabArgs,
    run: (adapters, args) => adapters.openTab(args.url),
  },
  closeTab: {
    spec: {
      name: "closeTab",
      kind: "write",
      description: "Close a tab by id. args: {tabId}. Write: needs user consent.",
    },
    argsSchema: closeTabArgs,
    run: (adapters, args) => adapters.closeTab(args.tabId),
  },
  copyText: {
    spec: {
      name: "copyText",
      kind: "write",
      description: "Copy text to the clipboard. args: {text}. Write: needs user consent.",
    },
    argsSchema: copyTextArgs,
    run: (adapters, args) => adapters.copyText(args.text),
  },
};

export type ToolResult =
  | { ok: true; value: unknown }
  | { ok: false; error: string };

/**
 * Validate args against the registry schema and run the tool. Never throws:
 * every failure (unknown tool, bad args, adapter error) comes back as a
 * result the model can read and the user can see.
 */
export async function executeTool(
  adapters: ToolAdapters,
  request: ToolRequest,
): Promise<ToolResult> {
  const def = toolRegistry[request.name];
  if (def === undefined) return { ok: false, error: `unknown tool: ${request.name}` };
  const parsed = def.argsSchema.safeParse(request.args);
  if (!parsed.success) {
    return { ok: false, error: `invalid args for ${request.name}: ${parsed.error.message}` };
  }
  try {
    return { ok: true, value: await def.run(adapters, parsed.data) };
  } catch (err) {
    return { ok: false, error: err instanceof Error ? err.message : String(err) };
  }
}
