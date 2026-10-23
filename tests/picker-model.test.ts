import { describe, expect, it } from "vitest";
import {
  PickerModel,
  applySelection,
  pickerFleet,
  resolveBinding,
  type PickerFleet,
} from "../src/chat/picker-model";
import type { NocheSettings } from "../src/settings/store";

const SETTINGS: NocheSettings = {
  providers: [
    {
      id: "p1",
      label: "Provider One",
      baseUrl: "http://localhost:1234",
      wire: "openai-completions",
      auth: { type: "none" },
      models: [
        { id: "m1", label: "Model One", contextWindow: 8192, reasoning: false, default: true },
        { id: "m2", contextWindow: 4096, reasoning: false, default: false },
      ],
    },
    {
      id: "p2",
      label: "Provider Two",
      baseUrl: "http://localhost:5678",
      wire: "anthropic-messages",
      auth: { type: "none" },
      models: [{ id: "z", contextWindow: 1024, reasoning: false, default: true }],
    },
  ],
  activeProviderId: "p1",
  activeModelId: "m2",
};

const P2_FLEET: PickerFleet = {
  providers: SETTINGS.providers.map((p) => ({
    id: p.id,
    label: p.label,
    models: p.models.map((m) => ({ id: m.id, label: m.label ?? m.id })),
  })),
  providerId: "p2",
  modelId: "z",
};

function harness(fleet: PickerFleet | Error) {
  let changes = 0;
  let commitError = false;
  const commits: { providerId: string; modelId: string | undefined }[] = [];
  const picker = new PickerModel({
    loadFleet: async () => {
      if (fleet instanceof Error) throw fleet;
      return fleet;
    },
    commit: async (providerId, modelId) => {
      commits.push({ providerId, modelId });
      if (commitError) throw new Error("unknown provider or model");
      return P2_FLEET;
    },
    onChange: () => {
      changes += 1;
    },
  });
  return {
    picker,
    changes: () => changes,
    commits,
    failCommits: () => {
      commitError = true;
    },
  };
}

describe("PickerModel", () => {
  it("is not ready before load and offers nothing", () => {
    const h = harness(pickerFleet(SETTINGS));
    expect(h.picker.snapshot()).toEqual({
      ready: false,
      providers: [],
      providerId: "",
      modelId: "",
    });
    expect(h.picker.binding()).toBeNull();
    expect(h.changes()).toBe(0);
  });

  it("adopts the loaded fleet as its selection", async () => {
    const h = harness(pickerFleet(SETTINGS));
    await h.picker.load();
    const snap = h.picker.snapshot();
    expect(snap.ready).toBe(true);
    expect(snap.providerId).toBe("p1");
    expect(snap.modelId).toBe("m2");
    expect(snap.providers).toEqual([
      {
        id: "p1",
        label: "Provider One",
        models: [
          { id: "m1", label: "Model One" },
          { id: "m2", label: "m2" },
        ],
      },
      {
        id: "p2",
        label: "Provider Two",
        models: [{ id: "z", label: "z" }],
      },
    ]);
    expect(h.picker.binding()).toEqual({ provider: "p1", model: "m2" });
    expect(h.changes()).toBe(1);
  });

  it("propagates fleet-load failure and stays not ready", async () => {
    const h = harness(new Error("background gone"));
    await expect(h.picker.load()).rejects.toThrow("background gone");
    expect(h.picker.snapshot().ready).toBe(false);
    expect(h.picker.binding()).toBeNull();
  });

  it("commits a pick and adopts the returned fleet", async () => {
    const h = harness(pickerFleet(SETTINGS));
    await h.picker.load();
    await expect(h.picker.select("p2")).resolves.toBe(true);
    expect(h.commits).toEqual([{ providerId: "p2", modelId: undefined }]);
    expect(h.picker.binding()).toEqual({ provider: "p2", model: "z" });
    expect(h.picker.snapshot().modelId).toBe("z");
    expect(h.changes()).toBe(2);
  });

  it("commits an explicit model id", async () => {
    const h = harness(pickerFleet(SETTINGS));
    await h.picker.load();
    await expect(h.picker.select("p1", "m1")).resolves.toBe(true);
    expect(h.commits).toEqual([{ providerId: "p1", modelId: "m1" }]);
  });

  it("cannot select before the first load", async () => {
    const h = harness(pickerFleet(SETTINGS));
    await expect(h.picker.select("p2")).resolves.toBe(false);
    expect(h.commits).toEqual([]);
    expect(h.changes()).toBe(0);
  });

  it("keeps the in-memory selection when the commit is rejected", async () => {
    const h = harness(pickerFleet(SETTINGS));
    await h.picker.load();
    h.failCommits();
    await expect(h.picker.select("p2")).resolves.toBe(false);
    expect(h.picker.binding()).toEqual({ provider: "p1", model: "m2" });
    expect(h.changes()).toBe(1);
  });
});

describe("applySelection", () => {
  it("persists a provider pick as its default model", () => {
    expect(applySelection(SETTINGS, "p2")).toMatchObject({
      activeProviderId: "p2",
      activeModelId: "z",
    });
  });

  it("persists an explicit model pick", () => {
    expect(applySelection(SETTINGS, "p1", "m1")).toMatchObject({
      activeProviderId: "p1",
      activeModelId: "m1",
    });
  });

  it("rejects unknown providers and unknown models", () => {
    expect(applySelection(SETTINGS, "ghost")).toBeNull();
    expect(applySelection(SETTINGS, "p1", "ghost")).toBeNull();
  });
});

describe("pickerFleet", () => {
  it("labels models, falling back to the raw id", () => {
    const fleet = pickerFleet(SETTINGS);
    expect(fleet.providers[0]?.models).toEqual([
      { id: "m1", label: "Model One" },
      { id: "m2", label: "m2" },
    ]);
    expect(fleet.providerId).toBe("p1");
    expect(fleet.modelId).toBe("m2");
  });

  it("seeds the provider default when no model id is stored", () => {
    const fleet = pickerFleet({ ...SETTINGS, activeModelId: undefined });
    expect(fleet.modelId).toBe("m1");
  });

  it("falls back to the first provider for a stale active id", () => {
    const fleet = pickerFleet({ ...SETTINGS, activeProviderId: "ghost" });
    expect(fleet.providerId).toBe("p1");
    expect(fleet.modelId).toBe("m2");
  });
});

describe("resolveBinding", () => {
  it("binds to stored settings when the send carries no binding", () => {
    expect(resolveBinding(SETTINGS, undefined)).toEqual({
      config: SETTINGS.providers[0],
      modelId: "m2",
    });
    expect(resolveBinding(SETTINGS, null)).toEqual({
      config: SETTINGS.providers[0],
      modelId: "m2",
    });
  });

  it("binds to the picked provider and model", () => {
    const resolved = resolveBinding(SETTINGS, { provider: "p1", model: "m1" });
    expect(resolved.config.id).toBe("p1");
    expect(resolved.modelId).toBe("m1");
  });

  it("falls back to the active provider for an unknown picked provider", () => {
    const ghost = { ...SETTINGS, activeProviderId: "ghost" };
    expect(resolveBinding(SETTINGS, { provider: "ghost", model: "m1" })).toEqual({
      config: SETTINGS.providers[0],
      modelId: "m2",
    });
    expect(resolveBinding(ghost, null).config.id).toBe("p1");
  });

  it("lets the provider default speak when the picked model is unknown there", () => {
    const resolved = resolveBinding(SETTINGS, { provider: "p1", model: "nope" });
    expect(resolved.config.id).toBe("p1");
    expect(resolved.modelId).toBeUndefined();
  });
});
