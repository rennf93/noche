import { describe, expect, it } from "vitest";
import { builtinSkills, parseBuiltinSkill } from "../src/skills/builtin";
import {
  loadRegistrySkills,
  matchCollection,
  parseRegistryIndex,
  suggestSkills,
  toSuggestion,
  type LoadedSkill,
  type SkillSuggestion,
} from "../src/skills/registry";

function skill(name: string, origin: LoadedSkill["origin"] = "registry"): LoadedSkill {
  return {
    meta: { name, description: `desc ${name}`, disableModelInvocation: false },
    body: `body of ${name}`,
    origin,
  };
}

function summary(name: string, origin: SkillSuggestion["origin"] = "registry"): SkillSuggestion {
  return { name, description: `desc ${name}`, origin };
}

describe("parseRegistryIndex", () => {
  it("accepts a valid index and ignores unknown keys", () => {
    const result = parseRegistryIndex(
      JSON.stringify({
        version: 1,
        note: "ignored",
        skills: [
          { name: "clip-notes", path: "skills/clip-notes/SKILL.md", extra: 1 },
        ],
      }),
    );
    expect(result).toEqual({
      ok: true,
      entries: [{ name: "clip-notes", path: "skills/clip-notes/SKILL.md" }],
    });
  });

  it("accepts an empty skills array", () => {
    expect(parseRegistryIndex('{"version":1,"skills":[]}')).toEqual({ ok: true, entries: [] });
  });

  it("rejects bad JSON and non-object payloads", () => {
    expect(parseRegistryIndex("{nope")).toEqual({ ok: false, error: "skills.json is not valid JSON" });
    expect(parseRegistryIndex("[]")).toEqual({ ok: false, error: "skills.json must be an object" });
    expect(parseRegistryIndex("null")).toEqual({ ok: false, error: "skills.json must be an object" });
    expect(parseRegistryIndex('"x"')).toEqual({ ok: false, error: "skills.json must be an object" });
  });

  it("rejects a wrong version and a missing skills array", () => {
    expect(parseRegistryIndex('{"version":2,"skills":[]}')).toEqual({
      ok: false,
      error: "unsupported skills.json version: 2",
    });
    expect(parseRegistryIndex('{"skills":[]}')).toEqual({
      ok: false,
      error: "unsupported skills.json version: undefined",
    });
    expect(parseRegistryIndex('{"version":1}')).toEqual({
      ok: false,
      error: "skills.json missing skills array",
    });
    expect(parseRegistryIndex('{"version":1,"skills":"x"}')).toEqual({
      ok: false,
      error: "skills.json missing skills array",
    });
  });

  it("rejects structurally broken entries", () => {
    expect(parseRegistryIndex('{"version":1,"skills":[7]}')).toEqual({
      ok: false,
      error: "skill entry must be an object",
    });
    expect(parseRegistryIndex('{"version":1,"skills":[null]}')).toEqual({
      ok: false,
      error: "skill entry must be an object",
    });
    expect(parseRegistryIndex('{"version":1,"skills":[[]]}')).toEqual({
      ok: false,
      error: "skill entry must be an object",
    });
  });

  it("rejects slash-unsafe names and empty names", () => {
    expect(parseRegistryIndex('{"version":1,"skills":[{"name":"","path":"p"}]}')).toEqual({
      ok: false,
      error: "invalid skill name: ",
    });
    expect(parseRegistryIndex('{"version":1,"skills":[{"name":"a b","path":"p"}]}')).toEqual({
      ok: false,
      error: "invalid skill name: a b",
    });
    expect(parseRegistryIndex('{"version":1,"skills":[{"name":"a/b","path":"p"}]}')).toEqual({
      ok: false,
      error: "invalid skill name: a/b",
    });
    expect(parseRegistryIndex('{"version":1,"skills":[{"name":9,"path":"p"}]}')).toEqual({
      ok: false,
      error: "invalid skill name: 9",
    });
  });

  it("rejects empty or missing paths and duplicate names", () => {
    expect(parseRegistryIndex('{"version":1,"skills":[{"name":"a"}]}')).toEqual({
      ok: false,
      error: "invalid path for skill: a",
    });
    expect(parseRegistryIndex('{"version":1,"skills":[{"name":"a","path":""}]}')).toEqual({
      ok: false,
      error: "invalid path for skill: a",
    });
    expect(
      parseRegistryIndex('{"version":1,"skills":[{"name":"a","path":"p"},{"name":"a","path":"q"}]}'),
    ).toEqual({ ok: false, error: "duplicate skill name: a" });
  });
});

describe("loadRegistrySkills", () => {
  const entries = [
    { name: "alpha", path: "alpha.md" },
    { name: "beta", path: "beta.md" },
  ];

  const alphaDoc = "---\nname: alpha\ndescription: first\n---\nAlpha body.";

  it("loads every entry whose SKILL.md agrees with the index", async () => {
    const sources = new Map([
      ["alpha.md", alphaDoc],
      ["beta.md", "---\nname: beta\ndescription: second\n---\nBeta body."],
    ]);
    const load = await loadRegistrySkills(entries, async (path) => {
      const found = sources.get(path);
      if (found === undefined) throw new Error(`missing ${path}`);
      return found;
    });
    expect(load.failures).toEqual([]);
    expect(load.skills.map((s) => s.meta.name)).toEqual(["alpha", "beta"]);
    expect(load.skills.every((s) => s.origin === "registry")).toBe(true);
    expect(load.skills[0]?.body).toBe("Alpha body.");
  });

  it("skips entries that fail to fetch, parse or agree with the index", async () => {
    const load = await loadRegistrySkills(
      [
        { name: "gone", path: "gone.md" },
        { name: "broken", path: "broken.md" },
        { name: "impostor", path: "impostor.md" },
        { name: "alpha", path: "alpha.md" },
      ],
      async (path) => {
        if (path === "gone.md") throw "network down";
        if (path === "broken.md") return "no frontmatter";
        if (path === "impostor.md") return "---\nname: other\ndescription: x\n---\n";
        return alphaDoc;
      },
    );
    expect(load.skills.map((s) => s.meta.name)).toEqual(["alpha"]);
    expect(load.failures).toEqual([
      "gone: network down",
      "broken: missing frontmatter open marker",
      "impostor: SKILL.md declares name other",
    ]);
  });

  it("formats Error rejections with their message", async () => {
    const load = await loadRegistrySkills([{ name: "a", path: "p" }], async () => {
      throw new Error("boom");
    });
    expect(load.failures).toEqual(["a: boom"]);
    expect(load.skills).toEqual([]);
  });

  it("loads nothing for an empty index", async () => {
    const load = await loadRegistrySkills([], async () => "");
    expect(load).toEqual({ skills: [], failures: [] });
  });
});

describe("suggestSkills", () => {
  const collection = [
    summary("mapping"),
    summary("man-page"),
    summary("rewrite"),
    summary("woman"),
  ];

  it("ranks prefix matches before substring matches", () => {
    const names = suggestSkills("ma", collection, 10).map((s) => s.name);
    expect(names).toEqual(["mapping", "man-page", "woman"]);
  });

  it("matches case-insensitively and keeps origin", () => {
    const [first] = suggestSkills("MAP", collection, 10);
    expect(first?.name).toBe("mapping");
    expect(first?.origin).toBe("registry");
    expect(first?.description).toBe("desc mapping");
  });

  it("returns everything in ranked order for an empty query", () => {
    expect(suggestSkills("", collection, 10).map((s) => s.name)).toEqual([
      "mapping",
      "man-page",
      "rewrite",
      "woman",
    ]);
  });

  it("caps at limit and tolerates a zero or negative limit", () => {
    expect(suggestSkills("", collection, 2).length).toBe(2);
    expect(suggestSkills("", collection, 0)).toEqual([]);
    expect(suggestSkills("", collection, -3)).toEqual([]);
  });

  it("collapses duplicate names, first origin winning", () => {
    const shadowed = [summary("dupe", "builtin"), summary("dupe", "registry"), summary("other")];
    const suggestions = suggestSkills("", shadowed, 10);
    expect(suggestions.map((s) => s.name)).toEqual(["dupe", "other"]);
    expect(suggestions[0]?.origin).toBe("builtin");
  });

  it("maps a loaded skill to its wire summary", () => {
    expect(toSuggestion(skill("clip-notes", "builtin"))).toEqual({
      name: "clip-notes",
      description: "desc clip-notes",
      origin: "builtin",
    });
  });
});

describe("matchCollection", () => {
  const collection = [skill("cite-check", "builtin"), skill("cite")];

  it("resolves an exact slash command over the whole collection", () => {
    const match = matchCollection("/cite-check", collection);
    expect(match?.skill.name).toBe("cite-check");
    expect(match?.rest).toBe("");
    expect(matchCollection("/cite is this true?", collection)?.rest).toBe("is this true?");
  });

  it("misses cleanly for unknown or boundary-breaking input", () => {
    expect(matchCollection("/nope", collection)).toBeUndefined();
    expect(matchCollection("/cite-checking", collection)).toBeUndefined();
  });
});

describe("builtin skills", () => {
  it("ships the three bundled skills, well-formed with bodies", () => {
    const builtins = builtinSkills();
    expect(builtins.map((s) => s.meta.name)).toEqual([
      "summarize-page",
      "draft-reply",
      "fact-check-clip",
    ]);
    expect(builtins.every((s) => s.origin === "builtin")).toBe(true);
    expect(builtins.every((s) => s.meta.description.length > 10)).toBe(true);
    expect(builtins.every((s) => s.body.includes("untrusted markers") || s.body.length > 40)).toBe(
      true,
    );
    expect(builtins.every((s) => !s.meta.disableModelInvocation)).toBe(true);
  });

  it("throws on a malformed builtin instead of shipping it", () => {
    expect(() => parseBuiltinSkill("bad", "not a skill md")).toThrow(
      "builtin skill bad is malformed: missing frontmatter open marker",
    );
  });
});
