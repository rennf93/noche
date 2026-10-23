import { describe, expect, it } from "vitest";
import { matchSkill, parseSkillMd, type SkillMeta } from "../src/skills/parse";

const DOC = [
  "---",
  'name: "cite-check"',
  "description: Checks claims in the page against sources",
  "disable-model-invocation: true",
  "---",
  "",
  "# Cite check",
  "",
  "Ask the model to verify each claim.",
].join("\n");

describe("parseSkillMd", () => {
  it("parses quoted and plain values, booleans and the body", () => {
    const result = parseSkillMd(DOC);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.skill.meta).toEqual({
        name: "cite-check",
        description: "Checks claims in the page against sources",
        disableModelInvocation: true,
      });
      expect(result.skill.body).toBe("# Cite check\n\nAsk the model to verify each claim.");
    }
  });

  it("defaults the disable flag and allows unknown keys and comments", () => {
    const source = ["---", "name: plain-name", "description: plain", "version: 9", "# note", "", "---", "Body"].join("\n");
    const result = parseSkillMd(source);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.skill.meta.disableModelInvocation).toBe(false);
      expect(result.skill.meta.name).toBe("plain-name");
      expect(result.skill.body).toBe("Body");
    }
  });

  it("keeps single-quoted and colon-bearing values literal", () => {
    const source = "---\nname: 'quoted'\ndescription: Time: the resource\n---\nBody";
    const result = parseSkillMd(source);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.skill.meta.name).toBe("quoted");
      expect(result.skill.meta.description).toBe("Time: the resource");
    }
  });

  it("leaves mismatched quotes literal", () => {
    const source = `---\nname: "mixed'\ndescription: d\n---\nBody`;
    const result = parseSkillMd(source);
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.skill.meta.name).toBe(`"mixed'`);
  });

  it("rejects structural problems", () => {
    expect(parseSkillMd("no frontmatter here").ok).toBe(false);
    expect(parseSkillMd("---\nname: x\ndescription: y\n").ok).toBe(false);
    expect(parseSkillMd("---\nbad line\ndescription: y\n---\n").ok).toBe(false);
    expect(parseSkillMd("").ok).toBe(false);
  });

  it("rejects missing or empty required fields and bad booleans", () => {
    expect(parseSkillMd("---\ndescription: y\n---\n").ok).toBe(false);
    expect(parseSkillMd("---\nname: x\n---\n").ok).toBe(false);
    expect(parseSkillMd("---\nname:\ndescription: y\n---\n").ok).toBe(false);
    expect(parseSkillMd("---\nname: x\ndescription:\n---\n").ok).toBe(false);
    const badBool = parseSkillMd("---\nname: x\ndescription: y\ndisable-model-invocation: yes\n---\n");
    expect(badBool).toEqual({
      ok: false,
      error: "disable-model-invocation must be true or false",
    });
  });
});

describe("matchSkill", () => {
  const skills: SkillMeta[] = [
    { name: "cite-check", description: "a", disableModelInvocation: false },
    { name: "cite", description: "b", disableModelInvocation: false },
  ];

  it("matches an exact slash command", () => {
    const match = matchSkill("/cite-check", skills);
    expect(match?.skill.name).toBe("cite-check");
    expect(match?.rest).toBe("");
  });

  it("matches a slash command with trailing text", () => {
    const match = matchSkill("/cite is this true?", skills);
    expect(match?.skill.name).toBe("cite");
    expect(match?.rest).toBe("is this true?");
  });

  it("requires a word boundary after the name", () => {
    expect(matchSkill("/cite-checking", skills)).toBeUndefined();
    expect(matchSkill("/cite:check", skills)).toBeUndefined();
    expect(matchSkill("cite-check", skills)).toBeUndefined();
    expect(matchSkill("/other", skills)).toBeUndefined();
  });
});
