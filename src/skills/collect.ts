import { loadSettings, type StorageArea } from "../settings/store";
import { builtinSkills } from "./builtin";
import { loadRegistrySkills, parseRegistryIndex, type LoadedSkill } from "./registry";

/**
 * The skill collection a surface sees: the bundled builtins, plus whatever a
 * configured git-hosted registry (settings.skillRegistryUrl) contributes.
 * The registry leg is best-effort by contract: any failure (fetch, index,
 * individual entry) degrades to a registryError note and the builtins stand
 * alone, so a dead or hostile registry can never blank out the slash menu.
 */

/** Text fetcher seam: URL in, body text out; non-2xx throws. */
export type SourceFetcher = (url: string) => Promise<string>;

export const fetchText: SourceFetcher = async (url) => {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.text();
};

export interface CollectedSkills {
  skills: LoadedSkill[];
  /** Why the registry contributed nothing (or partially); null when clean. */
  registryError: string | null;
}

/**
 * Builtins always; registry entries appended when a non-empty
 * skillRegistryUrl is configured and loads. Entry paths resolve against the
 * index URL, so a registry is relocatable as a whole.
 */
export async function collectSkills(
  area: StorageArea,
  fetchSource: SourceFetcher = fetchText,
): Promise<CollectedSkills> {
  const skills = builtinSkills();
  const settings = await loadSettings(area);
  const url = settings.skillRegistryUrl?.trim();
  if (url === undefined || url === "") return { skills, registryError: null };
  try {
    const index = await fetchSource(url);
    const parsed = parseRegistryIndex(index);
    if (!parsed.ok) return { skills, registryError: parsed.error };
    const resolved = await loadRegistrySkills(parsed.entries, (path) =>
      fetchSource(new URL(path, url).href),
    );
    return {
      skills: [...skills, ...resolved.skills],
      registryError: resolved.failures.length > 0 ? resolved.failures.join("; ") : null,
    };
  } catch (err) {
    return { skills, registryError: err instanceof Error ? err.message : String(err) };
  }
}
