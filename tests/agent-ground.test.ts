import { describe, expect, it } from "vitest";
import { groundElement, type PageOutline } from "../src/agent/ground";

const outline: PageOutline = {
  origin: "https://shop.test",
  elements: [
    { role: "banner", text: "Acme Shop", selector: "header" },
    { role: "textbox", name: "Search", value: "", selector: "#search" },
    { role: "link", name: "Sign in", text: "Sign in", selector: "#link-sign-in" },
    { role: "button", name: "Sign in", text: "Sign in", selector: "#button-sign-in" },
    { role: "button", name: "Sign in with SSO", text: "Sign in with SSO", selector: "#sso" },
    { role: "button", name: "Buy now", text: "Buy now", selector: "#buy" },
    {
      role: "checkbox",
      name: "Newsletter",
      value: "on",
      text: "Subscribe to newsletter",
      selector: "#newsletter",
    },
  ],
};

describe("groundElement", () => {
  it("prefers the exact role and name over prefix and substring name matches", () => {
    // 10 + 40 beats 10 + 24 (#sso); the same-named link is disqualified by role.
    expect(groundElement({ role: "button", name: "sign in" }, outline)).toBe("#button-sign-in");
  });

  it("normalizes case and surrounding whitespace on both sides", () => {
    const page: PageOutline = {
      origin: "https://x.test",
      elements: [{ role: "Button", name: "  Confirm Order  ", selector: "#confirm" }],
    };
    expect(groundElement({ role: " button ", name: "confirm order" }, page)).toBe("#confirm");
  });

  it("ranks name tiers: exact beats prefix beats substring", () => {
    const page: PageOutline = {
      origin: "https://x.test",
      elements: [
        { role: "link", name: "continue to the sign in portal", selector: "#contains" },
        { role: "link", name: "sign in portal", selector: "#prefix" },
        { role: "link", name: "sign in", selector: "#exact" },
      ],
    };
    expect(groundElement({ name: "sign in" }, page)).toBe("#exact");
  });

  it("disqualifies a role mismatch even when the name matches exactly", () => {
    const page: PageOutline = {
      origin: "https://x.test",
      elements: [
        { role: "link", name: "Pay", selector: "#link-pay" },
        { role: "button", name: "Pay", selector: "#button-pay" },
      ],
    };
    expect(groundElement({ role: "button", name: "pay" }, page)).toBe("#button-pay");
    expect(groundElement({ role: "link", name: "pay" }, page)).toBe("#link-pay");
  });

  it("with a role-only query, grounds to the first element of that role", () => {
    const page: PageOutline = {
      origin: "https://x.test",
      elements: [
        { role: "textbox", name: "Email", selector: "#email" },
        { role: "textbox", name: "Name", selector: "#name" },
      ],
    };
    expect(groundElement({ role: "textbox" }, page)).toBe("#email");
  });

  it("breaks score ties by document order", () => {
    const page: PageOutline = {
      origin: "https://x.test",
      elements: [
        { role: "button", name: "OK", selector: "#first" },
        { role: "button", name: "OK", selector: "#second" },
      ],
    };
    expect(groundElement({ role: "button", name: "ok" }, page)).toBe("#first");
  });

  it("matches the free-text signal against value first, then visible text", () => {
    const page: PageOutline = {
      origin: "https://x.test",
      elements: [
        { role: "searchbox", name: "Site search", value: "news archive", selector: "#search" },
        { role: "article", name: "Daily", text: "tech news", selector: "#article" },
      ],
    };
    expect(groundElement({ text: "news" }, page)).toBe("#search");
    expect(groundElement({ text: "tech" }, page)).toBe("#article");
  });

  it("ranks text tiers: exact beats prefix beats contains", () => {
    const page: PageOutline = {
      origin: "https://x.test",
      elements: [
        { role: "article", name: "b", text: "daily news feed", selector: "#contains" },
        { role: "article", name: "a", value: "news", selector: "#exact" },
      ],
    };
    expect(groundElement({ text: "news" }, page)).toBe("#exact");
  });

  it("an accessible-name match outweighs a free-text-only match", () => {
    const page: PageOutline = {
      origin: "https://x.test",
      elements: [
        { role: "link", name: "settings", text: "misc", selector: "#name-match" },
        { role: "link", name: "misc", text: "settings", selector: "#text-match" },
      ],
    };
    // 40 + 0 beats 0 + 20.
    expect(groundElement({ name: "settings", text: "settings" }, page)).toBe("#name-match");
  });

  it("combines role, name and text points, and the best total wins", () => {
    const page: PageOutline = {
      origin: "https://x.test",
      elements: [
        { role: "button", name: "settings", selector: "#role-name" },
        { role: "link", name: "settings", text: "settings", selector: "#link" },
        { role: "button", name: "settings overview", text: "settings", selector: "#role-name-text" },
      ],
    };
    // Totals: 10 + 40 vs -100 + 40 + 20 vs 10 + 24 + 20 = 50 vs -40 vs 54.
    expect(groundElement({ role: "button", name: "settings", text: "settings" }, page)).toBe(
      "#role-name-text",
    );
  });

  it("returns undefined for a signal-free query, a hopeless query, and an empty outline", () => {
    expect(groundElement({}, outline)).toBeUndefined();
    expect(groundElement({ role: "tab" }, outline)).toBeUndefined();
    expect(groundElement({ name: "nonexistent" }, outline)).toBeUndefined();
    expect(
      groundElement({ role: "button" }, { origin: "https://x.test", elements: [] }),
    ).toBeUndefined();
  });

  it("never grounds to an element serialized with an empty selector", () => {
    const page: PageOutline = {
      origin: "https://x.test",
      elements: [
        { role: "button", name: "target", selector: "" },
        { role: "button", name: "target", selector: "#real" },
      ],
    };
    expect(groundElement({ role: "button", name: "target" }, page)).toBe("#real");
  });

  it("is deterministic across repeated calls", () => {
    const query = { role: "button", name: "sign in" };
    const first = groundElement(query, outline);
    for (let i = 0; i < 5; i++) expect(groundElement(query, outline)).toBe(first);
  });
});
