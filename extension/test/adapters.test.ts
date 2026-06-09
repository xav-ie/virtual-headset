import { describe, it, expect, beforeEach } from "vitest";
import { pickAdapter, ADAPTERS } from "../src/adapters";

describe("pickAdapter", () => {
  it("selects the zoom adapter for *.zoom.us", () => {
    expect(pickAdapter("app.zoom.us")).toBe(ADAPTERS.zoom);
    expect(pickAdapter("us02web.zoom.us")).toBe(ADAPTERS.zoom);
  });

  it("selects the meet adapter for meet.google.com", () => {
    expect(pickAdapter("meet.google.com")).toBe(ADAPTERS.meet);
  });

  it("returns null for unsupported / look-alike hosts", () => {
    expect(pickAdapter("example.com")).toBeNull();
    expect(pickAdapter("zoom.us.evil.com")).toBeNull();
    expect(pickAdapter("meet.google.com.evil.com")).toBeNull();
  });
});

describe("zoom adapter", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
  });

  it("treats an exact 'unmute' label as muted", () => {
    document.body.innerHTML = `<button aria-label="unmute">x</button>`;
    const el = ADAPTERS.zoom.find()!;
    expect(el).not.toBeNull();
    expect(ADAPTERS.zoom.isMuted(el)).toBe(true);
  });

  it("treats an exact 'mute' label as unmuted", () => {
    document.body.innerHTML = `<button aria-label="mute">x</button>`;
    const el = ADAPTERS.zoom.find()!;
    expect(ADAPTERS.zoom.isMuted(el)).toBe(false);
  });

  it("matches longer labels via the fallback scan", () => {
    document.body.innerHTML = `
      <button aria-label="leave">l</button>
      <button aria-label="unmute my microphone">m</button>`;
    const el = ADAPTERS.zoom.find()!;
    expect(el).not.toBeNull();
    expect(ADAPTERS.zoom.isMuted(el)).toBe(true);
  });

  it("find() returns null when there is no mic button", () => {
    document.body.innerHTML = `<button aria-label="leave">x</button>`;
    expect(ADAPTERS.zoom.find()).toBeNull();
  });
});

describe("meet adapter", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
  });

  it("reads muted from data-is-muted=true", () => {
    document.body.innerHTML = `<button data-is-muted="true" aria-label="Turn on microphone">x</button>`;
    const el = ADAPTERS.meet.find()!;
    expect(el).not.toBeNull();
    expect(ADAPTERS.meet.isMuted(el)).toBe(true);
  });

  it("reads unmuted from data-is-muted=false", () => {
    document.body.innerHTML = `<button data-is-muted="false" aria-label="Turn off microphone">x</button>`;
    const el = ADAPTERS.meet.find()!;
    expect(ADAPTERS.meet.isMuted(el)).toBe(false);
  });

  it("falls back to the aria-label when data-is-muted is absent", () => {
    document.body.innerHTML = `<button aria-label="Turn on microphone (ctrl+d)">x</button>`;
    const el = ADAPTERS.meet.find()!;
    expect(el).not.toBeNull();
    expect(ADAPTERS.meet.isMuted(el)).toBe(true);
  });
});
