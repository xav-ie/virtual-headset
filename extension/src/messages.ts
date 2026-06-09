// Message shapes exchanged across the boundaries of the bridge:
//   native host  <-> background  <-> content script
//
// These are type-only declarations; esbuild erases this module at build time.

/** A forwardable audio input source (from `virtual-headset-ctl list-sources`). */
export interface Source {
  name: string;
  description: string;
  default: boolean; // the system/PipeWire default input
  configured: boolean; // pinned via set-source
}

/** Native host -> background. */
export type HostMessage =
  | { type: "state"; muted: boolean }
  | { type: "sources"; sources: Source[] }
  | { type: "pong" }
  | { type: "error"; message: string };

/** Background -> native host. */
export type HostCommand =
  | { type: "setMute"; muted: boolean }
  | { type: "toggle" }
  | { type: "query" }
  | { type: "listSources" }
  | { type: "setSource"; name: string }
  | { type: "clearSource" }
  | { type: "restartService" }
  | { type: "ping" };

/** Content script -> background. */
export type ContentMessage =
  | { type: "ready" }
  | { type: "webState"; muted: boolean };

/** Background -> content script. */
export type ContentCommand = { cmd: "apply"; muted: boolean };
