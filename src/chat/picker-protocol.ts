import type { PickerFleet } from "./picker-model";
import type { SkillSuggestion } from "../skills/registry";

/**
 * One-shot runtime messages behind the side panel's model picker and skills
 * slash-menu. The panel owns no storage and no zod: settings are validated by
 * the background's settings store, and every answer here is parsed again on
 * the panel side (parsePickerFleetResponse and friends), so a malformed or
 * hostile payload degrades to an error, never to a guess. Skills travel as
 * slash-menu summaries only; bodies never cross the wire until a chat run
 * asks for them.
 */

/** Panel -> background: the current picker fleet. */
export const PICKER_REQUEST = "noche:get-picker";
/** Panel -> background: commit a pick (model omitted = provider default). */
export const PICKER_SET = "noche:set-picker";
/** Panel -> background: slash-menu summaries for builtins plus the registry. */
export const SKILLS_REQUEST = "noche:get-skills";

/** Panel -> background payload for PICKER_SET. */
export interface PickerSetMessage {
  type: "noche:set-picker";
  providerId: string;
  modelId?: string;
}

export type PickerFleetResponse =
  | { ok: true; fleet: PickerFleet }
  | { ok: false; error: string };

export type PickerSetResponse = PickerFleetResponse;

export type SkillsResponse =
  | { ok: true; skills: SkillSuggestion[] }
  | { ok: false; error: string };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Validate an incoming PICKER_SET payload; null when malformed. */
export function parsePickerSetMessage(raw: unknown): Pick<PickerSetMessage, "providerId" | "modelId"> | null {
  if (!isRecord(raw) || raw.type !== PICKER_SET) return null;
  if (typeof raw.providerId !== "string" || raw.providerId === "") return null;
  if (raw.modelId !== undefined && typeof raw.modelId !== "string") return null;
  return { providerId: raw.providerId, modelId: raw.modelId as string | undefined };
}

function parseFleet(raw: unknown): PickerFleet | null {
  if (!isRecord(raw) || !Array.isArray(raw.providers)) return null;
  const providers = [];
  for (const candidate of raw.providers) {
    if (!isRecord(candidate)) return null;
    if (typeof candidate.id !== "string" || typeof candidate.label !== "string") return null;
    if (!Array.isArray(candidate.models)) return null;
    const models = [];
    for (const model of candidate.models) {
      if (!isRecord(model)) return null;
      if (typeof model.id !== "string" || typeof model.label !== "string") return null;
      models.push({ id: model.id, label: model.label });
    }
    providers.push({ id: candidate.id, label: candidate.label, models });
  }
  if (typeof raw.providerId !== "string" || typeof raw.modelId !== "string") return null;
  return { providers, providerId: raw.providerId, modelId: raw.modelId };
}

/** Validate a fleet answer; malformed payloads degrade to an error. */
export function parsePickerFleetResponse(raw: unknown): PickerFleetResponse {
  if (!isRecord(raw)) return { ok: false, error: "malformed picker response" };
  if (raw.ok === true) {
    const fleet = parseFleet(raw.fleet);
    return fleet === null ? { ok: false, error: "malformed fleet payload" } : { ok: true, fleet };
  }
  if (raw.ok === false && typeof raw.error === "string") return { ok: false, error: raw.error };
  return { ok: false, error: "malformed picker response" };
}

/** A set answer is the same shape: the committed fleet, or an error. */
export const parsePickerSetResponse = parsePickerFleetResponse;

function parseSuggestion(raw: unknown): SkillSuggestion | null {
  if (!isRecord(raw)) return null;
  if (typeof raw.name !== "string" || typeof raw.description !== "string") return null;
  if (raw.origin !== "builtin" && raw.origin !== "registry") return null;
  return { name: raw.name, description: raw.description, origin: raw.origin };
}

/** Validate a skills answer; malformed payloads degrade to an error. */
export function parseSkillsResponse(raw: unknown): SkillsResponse {
  if (!isRecord(raw)) return { ok: false, error: "malformed skills response" };
  if (raw.ok === true) {
    if (!Array.isArray(raw.skills)) return { ok: false, error: "malformed skills payload" };
    const skills: SkillSuggestion[] = [];
    for (const candidate of raw.skills) {
      const suggestion = parseSuggestion(candidate);
      if (suggestion === null) return { ok: false, error: "malformed skills payload" };
      skills.push(suggestion);
    }
    return { ok: true, skills };
  }
  if (raw.ok === false && typeof raw.error === "string") return { ok: false, error: raw.error };
  return { ok: false, error: "malformed skills response" };
}
