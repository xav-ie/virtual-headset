import { describe, it, expect } from "vitest";
import { Reconciler } from "../src/reconciler";

// Records the actions the reconciler takes, in order, as readable strings.
function setup() {
  const calls: string[] = [];
  const r = new Reconciler({
    applyToWeb: (m) => calls.push(`web:${m}`),
    setHeadsetMute: (m) => calls.push(`headset:${m}`),
    onChange: (s) => calls.push(`change:${s}`),
  });
  return { r, calls };
}

describe("Reconciler", () => {
  it("drives the web when the headset changes", () => {
    const { r, calls } = setup();
    r.fromHeadset(true);
    expect(r.state).toBe(true);
    expect(calls).toEqual(["change:true", "web:true"]);
  });

  it("drives the headset when the web changes", () => {
    const { r, calls } = setup();
    r.fromHeadset(false); // establish a known agreed state
    calls.length = 0;
    r.fromWeb(true);
    expect(r.state).toBe(true);
    expect(calls).toEqual(["change:true", "headset:true"]);
  });

  it("ignores a web echo of a headset-initiated change (no loop)", () => {
    const { r, calls } = setup();
    r.fromHeadset(true); // -> web:true
    calls.length = 0;
    r.fromWeb(true); // the content script echoing back our own click
    expect(calls).toEqual([]);
    expect(r.state).toBe(true);
  });

  it("ignores a headset echo of a web-initiated change (no loop)", () => {
    const { r, calls } = setup();
    r.fromHeadset(false);
    r.fromWeb(true); // -> headset:true
    calls.length = 0;
    r.fromHeadset(true); // the daemon's MuteChanged echoing our setMute
    expect(calls).toEqual([]);
    expect(r.state).toBe(true);
  });

  it("adopts the first web state when nothing is known yet", () => {
    const { r, calls } = setup();
    r.fromWeb(true);
    expect(r.state).toBe(true);
    expect(calls).toEqual(["change:true", "headset:true"]);
  });

  it("reset() returns to the unknown state", () => {
    const { r, calls } = setup();
    r.fromHeadset(true);
    calls.length = 0;
    r.reset();
    expect(r.state).toBeNull();
    expect(calls).toEqual(["change:null"]);
  });
});
