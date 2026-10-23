import { describe, expect, it } from "vitest";
import { defaultSettings } from "../src/settings/store";

describe("local fleet key handling", () => {
  it("uses bearer auth for the local fleet when a key is provided", () => {
    expect(defaultSettings("k").providers[0]?.auth.type).toBe("apiKey");
  });

  it("ships auth none when no key is configured (public clean build)", () => {
    expect(defaultSettings("").providers[0]?.auth.type).toBe("none");
  });
});
