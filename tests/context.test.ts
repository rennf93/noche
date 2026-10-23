// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { extractPage, bodyTextOf } from "../src/context/extract";
import { allocateBudget } from "../src/context/budget";
import { estimateTokens } from "../src/context/tokens";

function page(articles: string): Document {
  const doc = document.implementation.createHTMLDocument("A title");
  const article = doc.createElement("article");
  article.innerHTML = `<h1>Head</h1><p>${articles}</p>`;
  doc.body.appendChild(article);
  return doc;
}

describe("extractPage", () => {
  it("extracts readability content with origin and title", () => {
    const doc = page("Readable body text long enough to parse. ".repeat(10));
    Object.defineProperty(doc, "documentURI", {
      value: "https://example.com/post/1",
      configurable: true,
    });
    const out = extractPage(doc);
    expect(out.origin).toBe("https://example.com");
    expect(out.title).toBe("A title");
    expect(out.text).toContain("Readable body");
    expect(out.tokens).toBe(estimateTokens(out.text));
  });

  it("falls back to body text when readability bails", () => {
    const doc = document.implementation.createHTMLDocument("Fallback");
    Object.defineProperty(doc, "documentURI", {
      value: "https://bare.test/",
      configurable: true,
    });
    const p = doc.createElement("p");
    p.textContent = "plain fallback text";
    doc.body.appendChild(p);
    const out = extractPage(doc);
    expect(out.text).toContain("plain fallback text");
    expect(out.title).toBe("Fallback");
  });

  it("falls back to empty text on a bodyless document", () => {
    const doc = new DOMParser().parseFromString("<root/>", "text/xml");
    Object.defineProperty(doc, "documentURI", {
      value: "https://empty.test/",
      configurable: true,
    });
    const out = extractPage(doc);
    expect(out.text).toBe("");
    expect(out.tokens).toBe(0);
    expect(out.title).toBe("https://empty.test");
  });

  it("handles a null body without throwing", () => {
    const real = document.implementation.createHTMLDocument("No body");
    while (real.body.firstChild) real.body.removeChild(real.body.firstChild);
    const doc = new Proxy(real, {
      get(target, prop) {
        if (prop === "body") return null;
        return Reflect.get(target, prop);
      },
    }) as Document;
    Object.defineProperty(real, "documentURI", {
      value: "https://nobody.test/",
      configurable: true,
    });
    const out = extractPage(doc);
    expect(out.text).toBe("");
    expect(out.title).toBe("No body");
  });

  it("survives a document that makes Readability throw", () => {
    const doc = document.implementation.createDocument(null, "", null);
    Object.defineProperty(doc, "documentURI", {
      value: "https://hostile.test/",
      configurable: true,
    });
    const out = extractPage(doc);
    expect(out.origin).toBe("https://hostile.test");
    expect(typeof out.text).toBe("string");
  });

  it("uses the origin as title when the document has none", () => {
    const doc = document.implementation.createHTMLDocument("");
    Object.defineProperty(doc, "documentURI", {
      value: "https://untitled.test/",
      configurable: true,
    });
    const article = doc.createElement("article");
    const p = doc.createElement("p");
    p.textContent = "Substantial article body text without any heading. ".repeat(20);
    article.appendChild(p);
    doc.body.appendChild(article);
    const out = extractPage(doc);
    expect(out.title).toBe("https://untitled.test");
    expect(out.text).toContain("Substantial article");
  });
});

describe("bodyTextOf", () => {
  it("returns empty string for null, undefined and null-textContent bodies", () => {
    expect(bodyTextOf({ body: null } as unknown as Document)).toBe("");
    expect(bodyTextOf({ body: undefined } as unknown as Document)).toBe("");
    expect(bodyTextOf({ body: { textContent: null } } as unknown as Document)).toBe("");
  });

  it("returns the body text when present", () => {
    expect(bodyTextOf({ body: { textContent: "hello" } } as unknown as Document)).toBe("hello");
  });
});

describe("allocateBudget", () => {
  const tabs = [
    { tabId: 1, tokens: 100, active: true },
    { tabId: 2, tokens: 100 },
  ];

  it("returns zero allocations for no tabs or no usable window", () => {
    expect(allocateBudget({ contextWindow: 4096, tabs: [] })).toEqual([]);
    expect(
      allocateBudget({ contextWindow: 1024, tabs }), // below system reserve + output
    ).toEqual([
      { tabId: 1, allowed: 0, complete: false },
      { tabId: 2, allowed: 0, complete: false },
    ]);
  });

  it("fits everything when the window allows", () => {
    const out = allocateBudget({ contextWindow: 8192, tabs });
    expect(out).toEqual([
      { tabId: 1, allowed: 100, complete: true },
      { tabId: 2, allowed: 100, complete: true },
    ]);
  });

  it("splits overflow with active-tab priority and passes empty tabs through", () => {
    const out = allocateBudget({
      contextWindow: 1024 + 512 + 300,
      tabs: [
        { tabId: 1, tokens: 400, active: true },
        { tabId: 2, tokens: 100 },
        { tabId: 3, tokens: 0 },
      ],
    });
    expect(out[2]).toEqual({ tabId: 3, allowed: 0, complete: true });
    const a1 = out[0];
    const a2 = out[1];
    expect(a1?.allowed).toBe(225); // 300 usable, weight 3+1 -> 225/75
    expect(a2?.allowed).toBe(75);
    expect(a1?.complete).toBe(false);
    expect(a2?.complete).toBe(false);
  });

  it("caps an over-weighted tab at its own size", () => {
    const out = allocateBudget({
      contextWindow: 8192,
      tabs: [
        { tabId: 1, tokens: 4000, active: true },
        { tabId: 2, tokens: 10 },
      ],
    });
    expect(out[0]?.complete).toBe(true);
    expect(out[1]?.complete).toBe(true);
    expect(out[0]?.allowed).toBe(4000);
    expect(out[1]?.allowed).toBe(10);
  });
});

describe("estimateTokens", () => {
  it("rounds up chars over four", () => {
    expect(estimateTokens("")).toBe(0);
    expect(estimateTokens("abcd")).toBe(1);
    expect(estimateTokens("abcde")).toBe(2);
  });
});
