import type { ProviderConfig } from "./schema";

export interface ChatMessage {
  role: "system" | "user" | "assistant";
  content: string;
}

export interface StreamCallbacks {
  onText(text: string): void;
  /** Aborts the in-flight stream request when set (the rail's stop button). */
  signal?: AbortSignal;
}

export function authHeaders(config: ProviderConfig, apiKey?: string): Record<string, string> {
  if (config.auth.type === "none" || apiKey === undefined) return {};
  return config.auth.headerStyle === "x-api-key"
    ? { "x-api-key": apiKey }
    : { authorization: `Bearer ${apiKey}` };
}

export async function assertOk(response: Response, config: ProviderConfig): Promise<void> {
  if (response.ok) return;
  const body = await response.text().catch(() => "");
  throw new Error(`${config.id} HTTP ${response.status}: ${body.slice(0, 300)}`);
}
