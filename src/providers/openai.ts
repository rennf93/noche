import { createSseParser } from "./sse";
import type { ModelConfig, ProviderConfig } from "./schema";
import { assertOk, authHeaders, type ChatMessage, type StreamCallbacks } from "./shared";

export type { ChatMessage, StreamCallbacks };

/** Stream chat completions from any OpenAI-compatible endpoint (the local fleet default). */
export async function streamOpenAIChat(
  config: ProviderConfig,
  model: ModelConfig,
  messages: ChatMessage[],
  callbacks: StreamCallbacks,
  apiKey?: string,
  fetchImpl: typeof fetch = fetch,
): Promise<void> {
  const response = await fetchImpl(`${config.baseUrl}/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json", ...authHeaders(config, apiKey) },
    body: JSON.stringify({ model: model.id, stream: true, messages }),
    signal: callbacks.signal,
  });
  await assertOk(response, config);
  const body = response.body;
  if (!body) throw new Error(`${config.id}: empty response body`);
  const reader = body.getReader();
  const decoder = new TextDecoder();
  const parser = createSseParser();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    for (const event of parser.feed(decoder.decode(value, { stream: true }))) {
      if (event.data === "[DONE]") return;
      if (event.data === "") continue;
      const delta = JSON.parse(event.data).choices?.[0]?.delta?.content;
      if (typeof delta === "string" && delta !== "") callbacks.onText(delta);
    }
  }
  for (const event of parser.end()) {
    if (event.data === "[DONE]" || event.data === "") continue;
    const delta = JSON.parse(event.data).choices?.[0]?.delta?.content;
    if (typeof delta === "string" && delta !== "") callbacks.onText(delta);
  }
}
