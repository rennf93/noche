import { createSseParser } from "./sse";
import type { ModelConfig, ProviderConfig } from "./schema";
import { assertOk, authHeaders, type ChatMessage, type StreamCallbacks } from "./shared";

export type { ChatMessage, StreamCallbacks };

/** Stream messages from any Anthropic-compatible endpoint. */
export async function streamAnthropicChat(
  config: ProviderConfig,
  model: ModelConfig,
  messages: ChatMessage[],
  callbacks: StreamCallbacks,
  apiKey?: string,
  fetchImpl: typeof fetch = fetch,
): Promise<void> {
  const system = messages.filter((m) => m.role === "system").map((m) => m.content).join("\n");
  const rest = messages.filter((m) => m.role !== "system");
  const response = await fetchImpl(`${config.baseUrl}/messages`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "anthropic-version": "2023-06-01",
      ...authHeaders(config, apiKey),
    },
    body: JSON.stringify({
      model: model.id,
      stream: true,
      system: system === "" ? undefined : system,
      messages: rest,
    }),
    signal: callbacks.signal,
  });
  await assertOk(response, config);
  const body = response.body;
  if (!body) throw new Error(`${config.id}: empty response body`);
  const reader = body.getReader();
  const decoder = new TextDecoder();
  const parser = createSseParser();
  const handle = (data: string): boolean => {
    if (data === "") return false;
    const parsed = JSON.parse(data) as { type?: string; delta?: { text?: string } };
    if (parsed.type === "message_stop") return true;
    if (parsed.type === "content_block_delta" && typeof parsed.delta?.text === "string") {
      callbacks.onText(parsed.delta.text);
    }
    return false;
  };
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    for (const event of parser.feed(decoder.decode(value, { stream: true }))) {
      if (handle(event.data)) return;
    }
  }
  for (const event of parser.end()) {
    if (handle(event.data)) return;
  }
}
