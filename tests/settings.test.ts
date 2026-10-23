import { describe, expect, it } from "vitest";
import {
  activeProvider,
  defaultSettings,
  loadSettings,
  saveSettings,
  type StorageArea,
} from "../src/settings/store";

function memoryArea(initial: Record<string, unknown> = {}): StorageArea & {
  dump(): Record<string, unknown>;
} {
  const data = { ...initial };
  return {
    get: async (key) => data[key],
    set: async (key, value) => {
      data[key] = value;
    },
    dump: () => data,
  };
}

const validProvider = {
  id: "p1",
  label: "P1",
  baseUrl: "http://localhost:1234",
  wire: "openai-completions",
  auth: { type: "none" },
  models: [{ id: "m", contextWindow: 8192 }],
};

describe("settings store", () => {
  it("returns defaults when nothing is stored", async () => {
    const settings = await loadSettings(memoryArea());
    expect(settings.activeProviderId).toBe("local-fleet");
    expect(settings.providers[0]?.baseUrl).toBe("http://localhost:9990");
    expect(settings.providers[0]?.models[0]?.id).toBe("ornith-1.5-35b");
  });

  it("round-trips valid settings and drops invalid providers", async () => {
    const area = memoryArea();
    const settings = await loadSettings(area);
    settings.providers.push(validProvider as never);
    await saveSettings(area, settings);
    const reloaded = await loadSettings(area);
    expect(reloaded.providers.length).toBe(2);

    const area2 = memoryArea({
      settings: {
        providers: [validProvider, { id: "broken", wire: "grpc" }],
        activeProviderId: "p1",
        activeModelId: "m",
      },
    });
    const filtered = await loadSettings(area2);
    expect(filtered.providers.length).toBe(1);
    expect(filtered.activeModelId).toBe("m");
  });

  it("falls back to the first provider when the active id is missing or storage is garbage", async () => {
    const area = memoryArea({ settings: { providers: [validProvider], activeProviderId: "ghost" } });
    const s = await loadSettings(area);
    expect(s.activeProviderId).toBe("p1");
    expect(activeProvider(s).id).toBe("p1");
    const mismatched = { providers: s.providers, activeProviderId: "nope" };
    expect(activeProvider(mismatched as never).id).toBe("p1");

    const garbage = memoryArea({ settings: 42 });
    expect((await loadSettings(garbage)).activeProviderId).toBe("local-fleet");
    expect(activeProvider(defaultSettings()).id).toBe("local-fleet");
  });

  it("returns defaults for a non-array providers field", async () => {
    const area = memoryArea({ settings: { providers: "nope" } });
    expect((await loadSettings(area)).activeProviderId).toBe("local-fleet");
  });

  it("returns defaults when every stored provider is invalid", async () => {
    const area = memoryArea({ settings: { providers: [{ id: "x", wire: "grpc" }] } });
    expect((await loadSettings(area)).providers[0]?.id).toBe("local-fleet");
  });

  it("passes a string skill registry url through and drops other types", async () => {
    const kept = memoryArea({
      settings: { providers: [validProvider], activeProviderId: "p1", skillRegistryUrl: "https://raw.test/skills.json" },
    });
    expect((await loadSettings(kept)).skillRegistryUrl).toBe("https://raw.test/skills.json");

    const dropped = memoryArea({
      settings: { providers: [validProvider], activeProviderId: "p1", skillRegistryUrl: 42 },
    });
    expect((await loadSettings(dropped)).skillRegistryUrl).toBeUndefined();

    const absent = memoryArea({ settings: { providers: [validProvider], activeProviderId: "p1" } });
    expect((await loadSettings(absent)).skillRegistryUrl).toBeUndefined();
  });
});
