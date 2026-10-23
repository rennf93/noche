import { describe, expect, it } from "vitest";
import { SlashMenuModel, isSlashToken, MAX_SLASH_ITEMS } from "../src/chat/slash-menu";
import type { SkillSuggestion } from "../src/skills/registry";

function skill(name: string): SkillSuggestion {
  return { name, description: `desc ${name}`, origin: "builtin" };
}

function menu(names: SkillSuggestion[]): SlashMenuModel {
  return new SlashMenuModel(() => names);
}

describe("isSlashToken", () => {
  it("holds only for a bare slash token at position zero", () => {
    expect(isSlashToken("/")).toBe(true);
    expect(isSlashToken("/sum")).toBe(true);
    expect(isSlashToken("")).toBe(false);
    expect(isSlashToken("hello")).toBe(false);
    expect(isSlashToken("/has space")).toBe(false);
    expect(isSlashToken("/trail ")).toBe(false);
    expect(isSlashToken("\t/x")).toBe(false);
  });
});

describe("SlashMenuModel", () => {
  const names = ["summarize-page", "draft-reply", "fact-check-clip"].map(skill);

  it("starts closed with no query", () => {
    const model = menu(names);
    expect(model.isOpen()).toBe(false);
    expect(model.list()).toEqual([]);
    expect(model.activeIndex()).toBe(-1);
    expect(model.currentQuery()).toBe("");
  });

  it("opens on a slash token and lists ranked suggestions", () => {
    const model = menu(names);
    model.onInput("/f");
    expect(model.isOpen()).toBe(true);
    expect(model.currentQuery()).toBe("f");
    // "fact-check-clip" is a prefix hit; "draft-reply" only contains the f.
    expect(model.list().map((item) => item.name)).toEqual(["fact-check-clip", "draft-reply"]);
    expect(model.activeIndex()).toBe(0);
    expect(model.list()[0]?.description).toBe("desc fact-check-clip");
    expect(model.list()[0]?.origin).toBe("builtin");
  });

  it("reads the live skill source, so late registry loads appear", () => {
    const skills: SkillSuggestion[] = [];
    const model = new SlashMenuModel(() => skills);
    model.onInput("/");
    expect(model.isOpen()).toBe(false);
    skills.push(skill("late"));
    model.onInput("/");
    expect(model.list().map((item) => item.name)).toEqual(["late"]);
  });

  it("stays closed when nothing matches", () => {
    const model = menu(names);
    model.onInput("/zzz");
    expect(model.isOpen()).toBe(false);
    expect(model.activeIndex()).toBe(-1);
    expect(model.apply()).toBeNull();
  });

  it("closes on spaces and non-slash text", () => {
    const model = menu(names);
    model.onInput("/sum");
    model.onInput("/sum ");
    expect(model.isOpen()).toBe(false);
    model.onInput("hello");
    expect(model.isOpen()).toBe(false);
    expect(model.currentQuery()).toBe("");
  });

  it("caps the list at MAX_SLASH_ITEMS", () => {
    const many = menu(["a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8"].map(skill));
    many.onInput("/");
    expect(many.list().length).toBe(MAX_SLASH_ITEMS);
    expect(MAX_SLASH_ITEMS).toBe(6);
  });

  it("moves the active row and clamps at both ends", () => {
    const model = menu(names);
    model.onInput("/");
    expect(model.move(-1)).toBe(false);
    expect(model.activeIndex()).toBe(0);
    expect(model.move(1)).toBe(true);
    expect(model.activeIndex()).toBe(1);
    expect(model.move(1)).toBe(true);
    expect(model.activeIndex()).toBe(2);
    expect(model.move(1)).toBe(false);
    expect(model.activeIndex()).toBe(2);
    expect(model.move(-2)).toBe(true);
    expect(model.activeIndex()).toBe(0);
  });

  it("cannot move a closed menu", () => {
    const model = menu(names);
    expect(model.move(1)).toBe(false);
  });

  it("applies the active row as ready-to-finish composer text", () => {
    const model = menu(names);
    model.onInput("/dra");
    expect(model.apply()).toBe("/draft-reply ");
    model.onInput("/e");
    expect(model.list().map((item) => item.name)).toEqual(names.map((item) => item.name));
    expect(model.apply()).toBe("/summarize-page ");
    expect(model.move(1)).toBe(true);
    expect(model.apply()).toBe("/draft-reply ");
  });

  it("applies an explicit index and rejects out-of-range ones", () => {
    const model = menu(names);
    model.onInput("/");
    expect(model.apply(1)).toBe("/draft-reply ");
    expect(model.apply(99)).toBeNull();
    expect(model.apply(-1)).toBeNull();
  });

  it("never applies while closed", () => {
    const model = menu(names);
    model.onInput("plain words");
    expect(model.apply(0)).toBeNull();
  });

  it("close clears query, items and the active row", () => {
    const model = menu(names);
    model.onInput("/s");
    model.move(1);
    model.close();
    expect(model.isOpen()).toBe(false);
    expect(model.list()).toEqual([]);
    expect(model.activeIndex()).toBe(-1);
    expect(model.currentQuery()).toBe("");
    expect(model.apply()).toBeNull();
  });
});
