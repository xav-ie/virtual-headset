// Pure helpers for the panel, kept free of GTK/ags imports so they can be
// unit-tested (see ./test/logic.test.ts). The GTK rendering in Panel.tsx is
// not unit-tested; this is the logic worth pinning down.

export interface RawSource {
  name: string;
  description: string;
  default: boolean; // the system/PipeWire default input
  configured: boolean; // pinned via set-source
}

export interface Source extends RawSource {
  active: boolean; // the source actually being forwarded right now
}

// The forwarded source is the pinned one if any, else the system default
// (mirrors the daemon's get_source()). Annotate each row accordingly.
export function withActive(sources: RawSource[]): Source[] {
  const anyConfigured = sources.some((s) => s.configured);
  return sources.map((s) => ({
    ...s,
    active: anyConfigured ? s.configured : s.default,
  }));
}

// Parse one `virtual-headset-ctl monitor-mute` line. Returns the muted state,
// or null if the line isn't a recognizable state update.
export function parseMuteLine(line: string): boolean | null {
  try {
    const { class: cls } = JSON.parse(line) as { class?: string };
    if (cls === "muted") return true;
    if (cls === "unmuted") return false;
  } catch {
    // ignore non-JSON status lines
  }
  return null;
}
