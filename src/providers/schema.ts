import { z } from "zod";
import { defaultModelOf } from "./model";

/**
 * Provider configuration, modeled on hummin packages/ai's createProvider:
 * a provider is pure config (base URL, wire protocol, declared auth, model
 * catalog); local fleet endpoints, subscriptions and keyed cloud APIs are all
 * entries of this same shape. See docs/design/provider-layer.md.
 */
export const providerConfigSchema = z.object({
  id: z.string().min(1),
  label: z.string().min(1),
  baseUrl: z.string().url(),
  wire: z.enum(["openai-completions", "anthropic-messages"]),
  auth: z.discriminatedUnion("type", [
    z.object({ type: z.literal("none") }),
    z.object({
      type: z.literal("apiKey"),
      envVar: z.string().min(1).optional(),
      headerStyle: z.enum(["bearer", "x-api-key"]).default("bearer"),
    }),
  ]),
  models: z
    .array(
      z.object({
        id: z.string().min(1),
        label: z.string().min(1).optional(),
        contextWindow: z.number().int().positive(),
        maxTokens: z.number().int().positive().optional(),
        reasoning: z.boolean().default(false),
        default: z.boolean().default(false),
      }),
    )
    .min(1),
});

export type ProviderConfig = z.infer<typeof providerConfigSchema>;
export type ModelConfig = ProviderConfig["models"][number];

/** The model a provider binds by default: the one flagged default, else the first. */
export function defaultModel(config: ProviderConfig): ModelConfig {
  return defaultModelOf(config.models);
}
