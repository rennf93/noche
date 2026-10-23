import { providerConfigSchema, type ProviderConfig } from "../providers/schema";

/** User settings persisted in chrome.storage.local (never synced storage). */
export interface NocheSettings {
  providers: ProviderConfig[];
  activeProviderId: string;
  activeModelId?: string;
  /** Optional git-hosted skills.json index URL (src/skills/registry.ts). */
  skillRegistryUrl?: string;
}

/**
 * Local-endpoint key, injected at build time from VITE_NOCHE_LOCAL_KEY
 * (.env.local, gitignored). Empty in clean checkouts: the public build
 * ships with auth "none" and no secret anywhere in the tree.
 */
/* v8 ignore next 2: environment-dependent build glue, exercised by real builds */
export const LOCAL_FLEET_KEY: string = (import.meta.env.VITE_NOCHE_LOCAL_KEY as string | undefined) ?? "";

/** The shipped default: a local OpenAI-compatible endpoint (the fleet). */
export function defaultSettings(localKey: string = LOCAL_FLEET_KEY): NocheSettings {
  return {
    providers: [
      providerConfigSchema.parse({
        id: "local-fleet",
        label: "Local fleet",
        baseUrl: "http://localhost:9990",
        wire: "openai-completions",
        auth: localKey === "" ? { type: "none" } : { type: "apiKey", headerStyle: "bearer" },
        models: [{ id: "ornith-1.5-35b", label: "Ornith 1.5", contextWindow: 65536, default: true }],
      }),
    ],
    activeProviderId: "local-fleet",
  };
}

export interface StorageArea {
  get(key: string): Promise<unknown>;
  set(key: string, value: unknown): Promise<void>;
}

/** Read settings; missing or invalid data falls back to defaults (merged by provider id). */
export async function loadSettings(area: StorageArea): Promise<NocheSettings> {
  const raw = await area.get("settings");
  const fallback = defaultSettings();
  if (typeof raw !== "object" || raw === null) return fallback;
  const candidate = raw as Partial<NocheSettings>;
  const providers = Array.isArray(candidate.providers)
    ? candidate.providers
        .map((p) => providerConfigSchema.safeParse(p))
        .filter((r) => r.success)
        .map((r) => r.data)
    : [];
  if (providers.length === 0) return fallback;
  const activeProviderId =
    typeof candidate.activeProviderId === "string" &&
    providers.some((p) => p.id === candidate.activeProviderId)
      ? candidate.activeProviderId
      : providers[0].id;
  const active =
    typeof candidate.activeModelId === "string" ? candidate.activeModelId : undefined;
  const skillRegistryUrl =
    typeof candidate.skillRegistryUrl === "string" ? candidate.skillRegistryUrl : undefined;
  return { providers, activeProviderId, activeModelId: active, skillRegistryUrl };
}

export async function saveSettings(area: StorageArea, settings: NocheSettings): Promise<void> {
  await area.set("settings", settings);
}

/** The provider a conversation binds to right now. */
export function activeProvider(settings: NocheSettings): ProviderConfig {
  const found = settings.providers.find((p) => p.id === settings.activeProviderId);
  return found ?? settings.providers[0];
}
