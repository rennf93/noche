export interface SkillMeta {
  name: string;
  description: string;
  disableModelInvocation: boolean;
}

export interface ParsedSkill {
  meta: SkillMeta;
  /** Instruction text after the frontmatter, verbatim minus one leading newline. */
  body: string;
}

export type SkillParseResult =
  | { ok: true; skill: ParsedSkill }
  | { ok: false; error: string };

/**
 * Plain frontmatter value: single or double quotes are optional and stripped
 * only as a matching pair; everything else stays literal (no escapes, this is
 * a deliberately small YAML subset, not a YAML parser).
 */
function stripQuotes(value: string): string {
  if (value.length >= 2) {
    const first = value[0];
    const last = value[value.length - 1];
    if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
      return value.slice(1, -1);
    }
  }
  return value;
}

/**
 * Parse a SKILL.md: frontmatter with at most name, description and
 * disable-model-invocation (lowercase true/false), then a markdown body.
 * Unknown keys are ignored; a missing or empty name or description, a bad
 * boolean, a stray line or either missing marker is an error, never a guess.
 */
export function parseSkillMd(source: string): SkillParseResult {
  const lines = source.split("\n");
  if (lines[0].trim() !== "---") return { ok: false, error: "missing frontmatter open marker" };
  const fields = new Map<string, string>();
  let i = 1;
  for (; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line === "---") break;
    if (line === "" || line.startsWith("#")) continue;
    const colon = line.indexOf(":");
    if (colon === -1) return { ok: false, error: `invalid frontmatter line: ${line}` };
    fields.set(line.slice(0, colon).trim(), stripQuotes(line.slice(colon + 1).trim()));
  }
  if (i >= lines.length) return { ok: false, error: "missing frontmatter close marker" };
  const name = fields.get("name");
  const description = fields.get("description");
  if (name === undefined || name === "") return { ok: false, error: "frontmatter missing name" };
  if (description === undefined || description === "") {
    return { ok: false, error: "frontmatter missing description" };
  }
  const rawDisable = fields.get("disable-model-invocation");
  if (rawDisable !== undefined && rawDisable !== "true" && rawDisable !== "false") {
    return { ok: false, error: "disable-model-invocation must be true or false" };
  }
  return {
    ok: true,
    skill: {
      meta: {
        name,
        description,
        disableModelInvocation: rawDisable === "true",
      },
      body: lines.slice(i + 1).join("\n").replace(/^\n/, ""),
    },
  };
}

export interface SkillMatch {
  skill: SkillMeta;
  /** Text after the slash command, "" for an exact trigger. */
  rest: string;
}

/**
 * Slash-name triggering: "/name" or "/name rest of message" picks the skill.
 * The name must end at a word boundary (end or space), so "/foobar" never
 * fires the "foo" skill; matching is exact-case and array order breaks ties.
 */
export function matchSkill(input: string, skills: readonly SkillMeta[]): SkillMatch | undefined {
  for (const skill of skills) {
    const token = `/${skill.name}`;
    if (input === token) return { skill, rest: "" };
    if (input.startsWith(`${token} `)) return { skill, rest: input.slice(token.length + 1) };
  }
  return undefined;
}
