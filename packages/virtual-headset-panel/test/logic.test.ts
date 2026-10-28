import { describe, it, expect } from "vitest";
import {
  withActive,
  parseState,
  callRow,
  statusText,
  strengthLabel,
  meterFraction,
  levelFresh,
  INITIAL_STATE,
  type State,
} from "../logic";

const state = (s: Partial<State>): State => ({ ...INITIAL_STATE, ...s });

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

describe("parseState", () => {
  it("parses a state line, filling what's missing", () => {
    const s = parseState('{"call":"unmuted","muted":false,"source":"Mic"}');
    expect(s).toEqual(state({ call: "unmuted", muted: false, source: "Mic" }));
  });

  it("returns null for non-state lines", () => {
    expect(parseState("not json")).toBeNull();
    expect(parseState('{"text":"x"}')).toBeNull();
  });
});

describe("callRow", () => {
  it("leads with the call's mute state in a call", () => {
    expect(callRow(state({ call: "unmuted", muted: false }))).toMatchObject({
      title: "Live",
      live: true,
      button: "Mute",
      buttonLabel: "Mute the call",
    });
    expect(callRow(state({ call: "muted", muted: true }))).toMatchObject({
      title: "Muted",
      live: false,
      button: "Unmute",
    });
  });

  it("keeps the mute button outside a call, for the mic itself", () => {
    expect(callRow(state({ call: "none", muted: true }))).toEqual({
      title: "Not in a call",
      live: false,
      button: "Unmute",
      buttonLabel: "Unmute the mic",
    });
  });
});

describe("statusText", () => {
  it("names the mic in use while live, and says it's released while muted", () => {
    expect(statusText(state({ muted: false, source: "USB Mic" }))).toBe(
      "Using USB Mic",
    );
    expect(statusText(state({ muted: true, source: "USB Mic" }))).toBe(
      "Mic released while muted",
    );
  });
});

describe("strengthLabel", () => {
  it("shows dB below the top, and Max at it", () => {
    expect(strengthLabel(12.4)).toBe("12 dB");
    expect(strengthLabel(40)).toBe("Max");
  });
});

describe("meterFraction", () => {
  it("maps -70..0 dBFS onto 0..1, clamped", () => {
    expect(meterFraction(-70)).toBe(0);
    expect(meterFraction(-35)).toBe(0.5);
    expect(meterFraction(3)).toBe(1);
    expect(meterFraction(-Infinity)).toBe(0);
  });
});

describe("levelFresh", () => {
  it("treats a level older than half a second as a closed mic", () => {
    expect(levelFresh(1000, 1400)).toBe(true);
    expect(levelFresh(1000, 1600)).toBe(false);
  });
});
