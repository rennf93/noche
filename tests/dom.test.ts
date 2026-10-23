// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { appendTextDelta, chipGlyph, shouldStickToBottom } from "../src/ui/dom";

function container(): HTMLDivElement {
  return document.createElement("div");
}

describe("appendTextDelta", () => {
  it("appends only the new suffix as an enter-chunk span", () => {
    const box = container();
    expect(appendTextDelta(box, "Hel", 0)?.span.textContent).toBe("Hel");
    expect(appendTextDelta(box, "Hello", 3)?.span.textContent).toBe("lo");
    const spans = box.querySelectorAll("span.chunk");
    expect(spans.length).toBe(2);
    expect(spans[0]?.classList.contains("chunk-enter")).toBe(true);
    expect(box.textContent).toBe("Hello");
  });

  it("returns null when nothing grew", () => {
    const box = container();
    appendTextDelta(box, "Hel", 0);
    expect(appendTextDelta(box, "Hel", 3)).toBeNull();
    expect(box.querySelectorAll("span").length).toBe(1);
  });

  it("replaces content when the text shrinks (reset)", () => {
    const box = container();
    appendTextDelta(box, "longer text", 0);
    expect(appendTextDelta(box, "new", 11)).toBeNull();
    expect(box.textContent).toBe("new");
    expect(box.querySelectorAll("span").length).toBe(0);
  });
});

describe("shouldStickToBottom", () => {
  it("is true while within the slack and false when scrolled away", () => {
    const box = container();
    Object.defineProperty(box, "scrollTop", { value: 0, configurable: true });
    Object.defineProperty(box, "clientHeight", { value: 400, configurable: true });
    Object.defineProperty(box, "scrollHeight", { value: 420, configurable: true });
    expect(shouldStickToBottom(box)).toBe(true);
    Object.defineProperty(box, "scrollHeight", { value: 900, configurable: true });
    expect(shouldStickToBottom(box)).toBe(false);
    Object.defineProperty(box, "scrollTop", { value: 460, configurable: true });
    expect(shouldStickToBottom(box)).toBe(true);
    expect(shouldStickToBottom(box, 10)).toBe(false);
  });
});

describe("chipGlyph", () => {
  it("derives the host's first letter, www-stripped and uppercased", () => {
    expect(chipGlyph("https://example.com")).toBe("E");
    expect(chipGlyph("https://www.github.com")).toBe("G");
    expect(chipGlyph("http://docs.example.test/path")).toBe("D");
    expect(chipGlyph("http://192.168.1.1:8080")).toBe("1");
  });

  it("degrades empty or unlettered origins to a star", () => {
    expect(chipGlyph("")).toBe("*");
    expect(chipGlyph("____")).toBe("*");
  });
});
