import draftReplyRaw from "./builtin/draft-reply/SKILL.md?raw";
import factCheckClipRaw from "./builtin/fact-check-clip/SKILL.md?raw";
import summarizePageRaw from "./builtin/summarize-page/SKILL.md?raw";
import { parseSkillMd } from "./parse";
import type { LoadedSkill } from "./registry";

/**
 * The skills bundled with the extension itself. The SKILL.md sources ride in
 * the bundle as raw strings (Vite ?raw), so no runtime fetch is ever needed
 * for the builtins. A malformed builtin is a build bug and throws here, where
 * tests catch it; nothing ships a broken skill silently.
 */

const BUILTIN_SOURCES: ReadonlyArray<{ file: string; source: string }> = [
  { file: "summarize-page", source: summarizePageRaw },
  { file: "draft-reply", source: draftReplyRaw },
  { file: "fact-check-clip", source: factCheckClipRaw },
];

/** Parse one bundled SKILL.md; throws when the file is malformed. */
export function parseBuiltinSkill(file: string, source: string): LoadedSkill {
  const parsed = parseSkillMd(source);
  if (!parsed.ok) throw new Error(`builtin skill ${file} is malformed: ${parsed.error}`);
  return { meta: parsed.skill.meta, body: parsed.skill.body, origin: "builtin" };
}

/** The builtin collection, in bundle order (summarize, draft, fact-check). */
export function builtinSkills(): LoadedSkill[] {
  return BUILTIN_SOURCES.map(({ file, source }) => parseBuiltinSkill(file, source));
}
