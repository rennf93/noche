import { describe, expect, it } from "vitest";
import {
  PICKER_REQUEST,
  PICKER_SET,
  SKILLS_REQUEST,
  parsePickerFleetResponse,
  parsePickerSetMessage,
  parseSkillsResponse,
} from "../src/chat/picker-protocol";
import type { PickerFleet } from "../src/chat/picker-model";

const fleet: PickerFleet = {
  providers: [
    {
      id: "p1",
      label: "Provider One",
      models: [
        { id: "m1", label: "Model One" },
        { id: "m2", label: "m2" },
      ],
    },
  ],
  providerId: "p1",
  modelId: "m1",
};

describe("wire constants", () => {
  it("names the picker and skills requests", () => {
    expect(PICKER_REQUEST).toBe("noche:get-picker");
    expect(PICKER_SET).toBe("noche:set-picker");
    expect(SKILLS_REQUEST).toBe("noche:get-skills");
  });
});

describe("parsePickerSetMessage", () => {
  it("accepts a pick with and without a model id", () => {
    expect(parsePickerSetMessage({ type: "noche:set-picker", providerId: "p2", modelId: "z" })).toEqual({
      providerId: "p2",
      modelId: "z",
    });
    expect(parsePickerSetMessage({ type: "noche:set-picker", providerId: "p2" })).toEqual({
      providerId: "p2",
      modelId: undefined,
    });
  });

  it("rejects malformed payloads", () => {
    expect(parsePickerSetMessage(null)).toBeNull();
    expect(parsePickerSetMessage("nope")).toBeNull();
    expect(parsePickerSetMessage({ type: "other", providerId: "p" })).toBeNull();
    expect(parsePickerSetMessage({ type: "noche:set-picker" })).toBeNull();
    expect(parsePickerSetMessage({ type: "noche:set-picker", providerId: "" })).toBeNull();
    expect(parsePickerSetMessage({ type: "noche:set-picker", providerId: "p", modelId: 7 })).toBeNull();
  });
});

describe("parsePickerFleetResponse", () => {
  it("accepts a well-formed fleet", () => {
    expect(parsePickerFleetResponse({ ok: true, fleet })).toEqual({ ok: true, fleet });
  });

  it("degrades malformed envelopes and fleets to an error", () => {
    for (const broken of [undefined, "text"]) {
      expect(parsePickerFleetResponse(broken)).toEqual({ ok: false, error: "malformed picker response" });
    }
    for (const fleet of [
      null,
      { providers: "x", providerId: "p", modelId: "m" },
      { providers: [null], providerId: "p", modelId: "m" },
      { providers: [{ id: "p", label: "P", models: {} }], providerId: "p", modelId: "m" },
      { providers: [{ id: "p", label: "P", models: ["junk"] }], providerId: "p", modelId: "m" },
      { providers: [{ id: "p", label: "P", models: [{ id: "m" }] }], providerId: "p", modelId: "m" },
      { providers: [{ id: 7, label: "P", models: [] }], providerId: "p", modelId: "m" },
      { providers: [], providerId: 7, modelId: "m" },
      { providers: [], providerId: "p", modelId: null },
    ]) {
      expect(parsePickerFleetResponse({ ok: true, fleet })).toEqual({
        ok: false,
        error: "malformed fleet payload",
      });
    }
  });

  it("passes background errors through and rejects junk envelopes", () => {
    expect(parsePickerFleetResponse({ ok: false, error: "offline" })).toEqual({
      ok: false,
      error: "offline",
    });
    expect(parsePickerFleetResponse({ ok: false })).toEqual({
      ok: false,
      error: "malformed picker response",
    });
    expect(parsePickerFleetResponse({ ok: "maybe" })).toEqual({
      ok: false,
      error: "malformed picker response",
    });
  });
});

describe("parseSkillsResponse", () => {
  const skills = [
    { name: "summarize-page", description: "Summarize", origin: "builtin" },
    { name: "clip-notes", description: "Notes", origin: "registry" },
  ];

  it("accepts a well-formed list", () => {
    expect(parseSkillsResponse({ ok: true, skills })).toEqual({ ok: true, skills });
  });

  it("degrades malformed envelopes and lists to an error", () => {
    for (const broken of [undefined, 42]) {
      expect(parseSkillsResponse(broken)).toEqual({ ok: false, error: "malformed skills response" });
    }
    for (const skills of [
      "x",
      [null],
      [{ name: "a" }],
      [{ name: "a", description: "d", origin: "elsewhere" }],
      [{ name: 7, description: "d", origin: "builtin" }],
    ]) {
      expect(parseSkillsResponse({ ok: true, skills })).toEqual({
        ok: false,
        error: "malformed skills payload",
      });
    }
  });

  it("passes background errors through and rejects junk envelopes", () => {
    expect(parseSkillsResponse({ ok: false, error: "offline" })).toEqual({
      ok: false,
      error: "offline",
    });
    expect(parseSkillsResponse({ ok: true })).toEqual({
      ok: false,
      error: "malformed skills payload",
    });
    expect(parseSkillsResponse(null)).toEqual({ ok: false, error: "malformed skills response" });
    expect(parseSkillsResponse({ ok: "maybe" })).toEqual({
      ok: false,
      error: "malformed skills response",
    });
  });
});
