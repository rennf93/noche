import type { ModelConfig, ProviderConfig } from "./schema";
import { defaultModel } from "./schema";
import { streamOpenAIChat, type ChatMessage, type StreamCallbacks } from "./openai";
import { streamAnthropicChat } from "./anthropic";

export type { ChatMessage, StreamCallbacks };

export interface StreamRequest {
  config: ProviderConfig;
  messages: ChatMessage[];
  callbacks: StreamCallbacks;
  apiKey?: string;
  modelId?: string;
  /** Aborts the in-flight request when set (the rail's stop button). */
  signal?: AbortSignal;
}

/** The model a request binds to: the explicit id when known, else the default. */
export function resolveModel(config: ProviderConfig, modelId?: string): ModelConfig {
  if (modelId === undefined) return defaultModel(config);
  return config.models.find((m) => m.id === modelId) ?? defaultModel(config);
}

/** Stream a chat through whatever wire the provider config declares. */
export async function streamChat(request: StreamRequest): Promise<void> {
  const { config, messages, callbacks, apiKey, modelId, signal } = request;
  const model = resolveModel(config, modelId);
  const wired: StreamCallbacks = signal === undefined ? callbacks : { ...callbacks, signal };
  if (config.wire === "anthropic-messages") {
    return streamAnthropicChat(config, model, messages, wired, apiKey);
  }
  return streamOpenAIChat(config, model, messages, wired, apiKey);
}
