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

// The daemon's state, one line of `virtual-headset-ctl monitor-state`.
export interface State {
  call: "none" | "muted" | "unmuted";
  denoise: boolean;
  denoiseAvailable: boolean;
  keepOpen: boolean;
  muted: boolean;
  source: string;
  strength: number;
}

// Before the daemon answers: muted (it starts muted) and nothing else known.
export const INITIAL_STATE: State = {
  call: "none",
  denoise: false,
  denoiseAvailable: false,
  keepOpen: false,
  muted: true,
  source: "",
  strength: 40,
};

// Parse one `monitor-state` line, or null if it isn't a state.
export function parseState(line: string): State | null {
  try {
    const s = JSON.parse(line) as Partial<State>;
    if (typeof s.muted !== "boolean" || typeof s.call !== "string") return null;
    return { ...INITIAL_STATE, ...s } as State;
  } catch {
    return null;
  }
}

// The call row, the panel's most prominent line. In a call it names the call
// app's mute state; outside one the daemon's mute still gates the mic, so the
// button stays.
export function callRow(s: State): {
  title: string;
  live: boolean;
  button: string;
  buttonLabel: string; // for screen readers
} {
  const button = s.muted ? "Unmute" : "Mute";
  const buttonLabel =
    s.call === "none" ? `${button} the mic` : `${button} the call`;
  if (s.call === "none")
    return { title: "Not in a call", live: false, button, buttonLabel };
  return {
    title: s.muted ? "Muted" : "Live",
    live: !s.muted,
    button,
    buttonLabel,
  };
}

// The line under the mic picker.
export function statusText(s: State): string {
  if (s.muted) return "Mic released while muted";
  return s.source ? `Using ${s.source}` : "";
}

// DeepFilterNet sounds the same past ~40 dB of attenuation as unlimited, so the
// slider ends there, as "Max".
export const MAX_STRENGTH = 40;

export function strengthLabel(db: number): string {
  return db >= MAX_STRENGTH ? "Max" : `${Math.round(db)} dB`;
}

// The meter's range, as on the Mac: -70 dBFS (empty) to 0 (full).
export const METER_FLOOR = -70;

export function meterFraction(db: number): number {
  if (!Number.isFinite(db)) return 0;
  return Math.min(1, Math.max(0, (db - METER_FLOOR) / -METER_FLOOR));
}

// The daemon sends levels ~10 times a second while audio flows; a level older
// than this means the mic is closed.
export const LEVEL_STALE_MS = 500;

export function levelFresh(lastAt: number, now: number): boolean {
  return now - lastAt < LEVEL_STALE_MS;
}
