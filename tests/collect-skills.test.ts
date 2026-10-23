import { describe, expect, it, vi } from "vitest";
import { collectSkills, fetchText, type SourceFetcher } from "../src/skills/collect";
import type { StorageArea } from "../src/settings/store";

function area(settings: unknown): StorageArea {
  return {
    get: async (key) => (key === "settings" ? settings : undefined),
    set: async () => undefined,
  };
}

const REGISTRY_URL = "https://raw.test/reg/main/skills.json";

/** Minimal provider the settings store accepts (schema-valid). */
const validProvider = {
  id: "p1",
  label: "P1",
  baseUrl: "http://localhost:1234",
  wire: "openai-completions",
  auth: { type: "none" },
  models: [{ id: "m", contextWindow: 8192 }],
};

/** An index with one good entry, resolved relative to the index URL. */
function registryFetcher(log: string[]): SourceFetcher {
  return async (url) => {
    log.push(url);
    if (url === REGISTRY_URL) {
      return JSON.stringify({ version: 1, skills: [{ name: "clip-notes", path: "clip/SKILL.md" }] });
    }
    if (url === "https://raw.test/reg/main/clip/SKILL.md") {
      return "---\nname: clip-notes\ndescription: Registry skill\n---\nBody.";
    }
    throw new Error(`404 at ${url}`);
  };
}

describe("collectSkills", () => {
  it("returns just the builtins when no registry is configured", async () => {
    const collected = await collectSkills(area({ providers: [], activeProviderId: "x" }));
    expect(collected.registryError).toBeNull();
    expect(collected.skills.map((s) => s.meta.name)).toEqual([
      "summarize-page",
      "draft-reply",
      "fact-check-clip",
    ]);
  });

  it("treats a blank registry url as unconfigured", async () => {
    const fetched: string[] = [];
    const collected = await collectSkills(
      area({
        providers: [validProvider],
        activeProviderId: "p1",
        skillRegistryUrl: "   ",
      }),
      registryFetcher(fetched),
    );
    expect(collected.registryError).toBeNull();
    expect(fetched).toEqual([]);
  });

  it("appends registry skills, resolving entry paths against the index url", async () => {
    const fetched: string[] = [];
    const collected = await collectSkills(
      area({ providers: [validProvider], activeProviderId: "p1", skillRegistryUrl: REGISTRY_URL }),
      registryFetcher(fetched),
    );
    expect(collected.registryError).toBeNull();
    expect(collected.skills.map((s) => s.meta.name)).toEqual([
      "summarize-page",
      "draft-reply",
      "fact-check-clip",
      "clip-notes",
    ]);
    expect(collected.skills[3]?.origin).toBe("registry");
    expect(fetched).toEqual([
      REGISTRY_URL,
      "https://raw.test/reg/main/clip/SKILL.md",
    ]);
  });

  it("degrades to builtins when the index fetch throws (Error and non-Error)", async () => {
    const failing: SourceFetcher = async () => {
      throw new Error("offline");
    };
    const asError = await collectSkills(
      area({ providers: [validProvider], activeProviderId: "p1", skillRegistryUrl: REGISTRY_URL }),
      failing,
    );
    expect(asError.registryError).toBe("offline");
    expect(asError.skills.length).toBe(3);

    const nonError: SourceFetcher = async () => {
      throw 7;
    };
    const asString = await collectSkills(
      area({ providers: [validProvider], activeProviderId: "p1", skillRegistryUrl: REGISTRY_URL }),
      nonError,
    );
    expect(asString.registryError).toBe("7");
    expect(asString.skills.length).toBe(3);
  });

  it("degrades to builtins when the index payload is invalid", async () => {
    const collected = await collectSkills(
      area({ providers: [validProvider], activeProviderId: "p1", skillRegistryUrl: REGISTRY_URL }),
      async () => "not json",
    );
    expect(collected.registryError).toBe("skills.json is not valid JSON");
    expect(collected.skills.length).toBe(3);
  });

  it("keeps good entries and joins per-entry failures", async () => {
    const mixed: SourceFetcher = async (url) => {
      if (url === REGISTRY_URL) {
        return JSON.stringify({
          version: 1,
          skills: [
            { name: "good", path: "good.md" },
            { name: "gone", path: "gone.md" },
            { name: "broken", path: "broken.md" },
          ],
        });
      }
      if (url.endsWith("good.md")) {
        return "---\nname: good\ndescription: ok\n---\nBody.";
      }
      if (url.endsWith("broken.md")) return "garbage";
      throw new Error("missing");
    };
    const collected = await collectSkills(
      area({ providers: [validProvider], activeProviderId: "p1", skillRegistryUrl: REGISTRY_URL }),
      mixed,
    );
    expect(collected.skills.map((s) => s.meta.name)).toContain("good");
    expect(collected.registryError).toBe(
      "gone: missing; broken: missing frontmatter open marker",
    );
  });
});

describe("fetchText", () => {
  it("returns the body text on a 2xx response", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({ ok: true, text: async () => "payload" })),
    );
    try {
      await expect(fetchText("https://x.test/a")).resolves.toBe("payload");
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("throws a status error on a non-2xx response", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({ ok: false, status: 404 })),
    );
    try {
      await expect(fetchText("https://x.test/a")).rejects.toThrow("HTTP 404");
    } finally {
      vi.unstubAllGlobals();
    }
  });
});
