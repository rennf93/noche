import { matchSkill, parseSkillMd, type SkillMatch, type SkillMeta } from "./parse";

/**
 * Git-hosted skill registry: a skills.json index at a stable URL (a raw
 * githubusercontent path, a release asset, a self-hosted mirror) naming one
 * SKILL.md per entry by path relative to the index. The index is the source
 * of truth for what exists; each SKILL.md's own frontmatter must agree with
 * it. Everything here is pure: callers inject the fetcher, malformed input
 * fails closed per entry so one bad skill never poisons the collection.
 */

/** One skills.json entry: slash-safe name plus a path to its SKILL.md. */
export interface RegistryEntry {
  name: string;
  path: string;
}

/** A skill resolved into the collection, tagged with where it came from. */
export interface LoadedSkill {
  meta: SkillMeta;
  body: string;
  origin: "builtin" | "registry";
}

/** The only skills.json shape this loader accepts. */
const REGISTRY_VERSION = 1;

export type RegistryIndexResult =
  | { ok: true; entries: RegistryEntry[] }
  | { ok: false; error: string };

/** Skill names double as slash commands: no whitespace, no path separators. */
function validName(name: string): boolean {
  return name !== "" && !/\s/.test(name) && !name.includes("/");
}

/**
 * Validate a skills.json payload. Unknown top-level keys and unknown entry
 * keys are ignored; anything structurally wrong (bad JSON, wrong version,
 * missing skills array, a malformed or duplicate entry) is a single error,
 * never a partial guess.
 */
export function parseRegistryIndex(source: string): RegistryIndexResult {
  let value: unknown;
  try {
    value = JSON.parse(source);
  } catch {
    return { ok: false, error: "skills.json is not valid JSON" };
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return { ok: false, error: "skills.json must be an object" };
  }
  const record = value as Record<string, unknown>;
  if (record.version !== REGISTRY_VERSION) {
    return { ok: false, error: `unsupported skills.json version: ${String(record.version)}` };
  }
  if (!Array.isArray(record.skills)) {
    return { ok: false, error: "skills.json missing skills array" };
  }
  const entries: RegistryEntry[] = [];
  const seen = new Set<string>();
  for (const raw of record.skills) {
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
      return { ok: false, error: "skill entry must be an object" };
    }
    const entry = raw as Record<string, unknown>;
    const { name, path } = entry;
    if (typeof name !== "string" || !validName(name)) {
      return { ok: false, error: `invalid skill name: ${String(name)}` };
    }
    if (typeof path !== "string" || path === "") {
      return { ok: false, error: `invalid path for skill: ${name}` };
    }
    if (seen.has(name)) return { ok: false, error: `duplicate skill name: ${name}` };
    seen.add(name);
    entries.push({ name, path });
  }
  return { ok: true, entries };
}

/** What one registry pass produced: the skills that loaded, why others did not. */
export interface RegistryLoad {
  skills: LoadedSkill[];
  /** One "name: reason" line per skipped entry, in index order. */
  failures: string[];
}

/**
 * Load every entry through the injected fetcher and parse its SKILL.md.
 * An entry that fails to fetch, parse or agree with its index name is
 * skipped and reported; the rest of the collection still loads.
 */
export async function loadRegistrySkills(
  entries: readonly RegistryEntry[],
  fetchSource: (path: string) => Promise<string>,
): Promise<RegistryLoad> {
  const skills: LoadedSkill[] = [];
  const failures: string[] = [];
  for (const entry of entries) {
    let source: string;
    try {
      source = await fetchSource(entry.path);
    } catch (err) {
      failures.push(`${entry.name}: ${err instanceof Error ? err.message : String(err)}`);
      continue;
    }
    const parsed = parseSkillMd(source);
    if (!parsed.ok) {
      failures.push(`${entry.name}: ${parsed.error}`);
      continue;
    }
    if (parsed.skill.meta.name !== entry.name) {
      failures.push(`${entry.name}: SKILL.md declares name ${parsed.skill.meta.name}`);
      continue;
    }
    skills.push({ meta: parsed.skill.meta, body: parsed.skill.body, origin: "registry" });
  }
  return { skills, failures };
}

/** A slash-menu row: what to show and in what order the picker ranks it. */
export interface SkillSuggestion {
  name: string;
  description: string;
  origin: LoadedSkill["origin"];
}

/**
 * Suggestions for a slash-menu query: case-insensitive, name-prefix matches
 * ranked before substring matches, duplicate names collapsed (first wins, so
 * builtins shadow a registry skill of the same name), capped at limit. The
 * input is the same summary shape the wire and the menu speak.
 */
export function suggestSkills(
  query: string,
  skills: readonly SkillSuggestion[],
  limit: number,
): SkillSuggestion[] {
  const needle = query.toLowerCase();
  const seen = new Set<string>();
  const prefixes: SkillSuggestion[] = [];
  const substrings: SkillSuggestion[] = [];
  for (const skill of skills) {
    const name = skill.name.toLowerCase();
    if (seen.has(name)) continue;
    seen.add(name);
    if (name.startsWith(needle)) prefixes.push(skill);
    else if (name.includes(needle)) substrings.push(skill);
  }
  return [...prefixes, ...substrings].slice(0, Math.max(0, limit));
}

/** The slash-menu summary of a loaded skill (the wire shape, too). */
export function toSuggestion(skill: LoadedSkill): SkillSuggestion {
  return { name: skill.meta.name, description: skill.meta.description, origin: skill.origin };
}

/**
 * The registry matcher: exact slash-command resolution ("/name rest") over a
 * whole collection, builtins and registry alike. Same boundary and tie rules
 * as matchSkill; collection order decides ties, so callers pass builtins first.
 */
export function matchCollection(input: string, skills: readonly LoadedSkill[]): SkillMatch | undefined {
  const metas: SkillMeta[] = skills.map((skill) => skill.meta);
  return matchSkill(input, metas);
}
