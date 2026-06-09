import { describe, it, expect } from "vitest";
import { withActive, parseMuteLine } from "../logic";

describe("withActive", () => {
  it("marks the pinned source active when one is configured", () => {
    const out = withActive([
      { name: "a", description: "A", default: true, configured: false },
      { name: "b", description: "B", default: false, configured: true },
    ]);
    expect(out.find((s) => s.name === "b")!.active).toBe(true);
    expect(out.find((s) => s.name === "a")!.active).toBe(false);
  });

  it("falls back to the system default when nothing is pinned", () => {
    const out = withActive([
      { name: "a", description: "A", default: true, configured: false },
      { name: "b", description: "B", default: false, configured: false },
    ]);
    expect(out.find((s) => s.name === "a")!.active).toBe(true);
    expect(out.find((s) => s.name === "b")!.active).toBe(false);
  });
});

describe("parseMuteLine", () => {
  it("parses muted / unmuted lines", () => {
    expect(parseMuteLine('{"class":"muted"}')).toBe(true);
    expect(parseMuteLine('{"class":"unmuted"}')).toBe(false);
  });

  it("returns null for non-state lines", () => {
    expect(parseMuteLine("not json")).toBeNull();
    expect(parseMuteLine('{"text":"x"}')).toBeNull();
  });
});
