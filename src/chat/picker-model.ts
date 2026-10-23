import { defaultModelOf } from "../providers/model";
import type { ProviderConfig } from "../providers/schema";
import type { NocheSettings } from "../settings/store";

/**
 * The side panel's model picker, isolated from both the DOM and the wire: a
 * selection over the settings fleet, persisted through the background on
 * every change, plus the per-conversation binding each send carries.
 *
 * Semantics: the dropdowns are fed entirely by NocheSettings (via
 * pickerFleet, below). A user pick rebinds the live conversation immediately
 * (subsequent sends carry the picked binding explicitly, so a settings
 * change from another context can never swap the model mid-conversation) and
 * is persisted as the new default, so the choice survives the panel and the
 * browser. The panel never touches storage or zod itself: the background
 * validates with the settings store and answers with the authoritative fleet
 * (chat/picker-protocol.ts), which this model adopts verbatim.
 */

/** The provider/model pair a send binds its run to. */
export interface RunBinding {
  provider: string;
  model: string;
}

export interface PickerOption {
  id: string;
  label: string;
}

export interface PickerProviderOption extends PickerOption {
  models: PickerOption[];
}

/** What the picker offers and where the selection stands, per settings. */
export interface PickerFleet {
  providers: PickerProviderOption[];
  providerId: string;
  modelId: string;
}

export interface PickerSnapshot extends PickerFleet {
  /** False until the first fleet load; the UI keeps the dropdowns hidden until then. */
  ready: boolean;
}

/** What a chat run binds to given the stored settings and an optional send binding. */
export function resolveBinding(
  settings: NocheSettings,
  binding: RunBinding | null | undefined,
): { config: ProviderConfig; modelId?: string } {
  if (binding === undefined || binding === null) {
    return { config: activeProvider(settings), modelId: settings.activeModelId };
  }
  const provider = settings.providers.find((p) => p.id === binding.provider);
  if (provider === undefined) {
    return { config: activeProvider(settings), modelId: settings.activeModelId };
  }
  const modelId = provider.models.some((m) => m.id === binding.model) ? binding.model : undefined;
  return { config: provider, modelId };
}

function activeProvider(settings: NocheSettings): ProviderConfig {
  const found = settings.providers.find((p) => p.id === settings.activeProviderId);
  return found ?? settings.providers[0];
}

/**
 * Validate a user pick against settings and return the persisted form.
 * Unknown provider or model ids are null (never a guess); omitting the model
 * picks the provider's default.
 */
export function applySelection(
  settings: NocheSettings,
  providerId: string,
  modelId?: string,
): NocheSettings | null {
  const provider = settings.providers.find((p) => p.id === providerId);
  if (provider === undefined) return null;
  const model =
    modelId === undefined
      ? defaultModelOf(provider.models)
      : provider.models.find((m) => m.id === modelId);
  if (model === undefined) return null;
  return { ...settings, activeProviderId: provider.id, activeModelId: model.id };
}

/** The picker view of settings: labeled options plus the seeded selection. */
export function pickerFleet(settings: NocheSettings): PickerFleet {
  const providers = settings.providers.map((p) => ({
    id: p.id,
    label: p.label,
    models: p.models.map((m) => ({ id: m.id, label: m.label ?? m.id })),
  }));
  const provider = activeProvider(settings);
  const model =
    provider.models.find((m) => m.id === settings.activeModelId) ?? defaultModelOf(provider.models);
  return { providers, providerId: provider.id, modelId: model.id };
}

export interface PickerDeps {
  /** Fetch the authoritative fleet (panel: a get-picker round trip). */
  loadFleet(): Promise<PickerFleet>;
  /** Commit a pick; resolves with the new fleet or rejects when invalid. */
  commit(providerId: string, modelId: string | undefined): Promise<PickerFleet>;
  onChange(): void;
}

export class PickerModel {
  private fleet: PickerFleet | null = null;

  constructor(private readonly deps: PickerDeps) {}

  /** Load the fleet and adopt it as the selection. */
  async load(): Promise<void> {
    this.fleet = await this.deps.loadFleet();
    this.deps.onChange();
  }

  snapshot(): PickerSnapshot {
    if (this.fleet === null) {
      return { ready: false, providers: [], providerId: "", modelId: "" };
    }
    return { ready: true, ...this.fleet };
  }

  /**
   * Commit a user pick. Before the first load, or when the background
   * rejects the ids or the write fails, this is a no-op (false) and the
   * in-memory selection stands; a successful commit adopts the returned
   * fleet, so the panel always shows what the background persisted.
   */
  async select(providerId: string, modelId?: string): Promise<boolean> {
    if (this.fleet === null) return false;
    let fleet: PickerFleet;
    try {
      fleet = await this.deps.commit(providerId, modelId);
    } catch {
      return false;
    }
    this.fleet = fleet;
    this.deps.onChange();
    return true;
  }

  /** The explicit binding sends carry; null until the first fleet load. */
  binding(): RunBinding | null {
    if (this.fleet === null) return null;
    return { provider: this.fleet.providerId, model: this.fleet.modelId };
  }
}
