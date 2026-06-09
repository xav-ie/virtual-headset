// Per-site adapters for reading/driving the conferencing web app's mic button.
//
// These track third-party DOM that changes without notice — they're the most
// likely thing to break, so they're isolated here (free of browser/extension
// globals) and unit-tested against jsdom fixtures in ../test/adapters.test.ts.

export interface Adapter {
  /** Find the mic toggle button, or null if not present yet. */
  find(): HTMLElement | null;
  /** Whether the given button currently means "muted". */
  isMuted(el: HTMLElement): boolean;
}

export const ADAPTERS: Record<"zoom" | "meet", Adapter> = {
  zoom: {
    // Zoom's mic button carries aria-label "mute"/"unmute"; the label names
    // the *action*, so "unmute" means it is currently muted.
    find() {
      const direct = document.querySelector<HTMLElement>(
        'button[aria-label="mute" i], button[aria-label="unmute" i]',
      );
      if (direct) return direct;
      return (
        [...document.querySelectorAll<HTMLElement>("button[aria-label]")].find(
          (b) =>
            /^(un)?mute\b/i.test((b.getAttribute("aria-label") || "").trim()),
        ) || null
      );
    },
    isMuted(el) {
      return (el.getAttribute("aria-label") || "")
        .trim()
        .toLowerCase()
        .startsWith("unmute");
    },
  },

  meet: {
    // Meet's mic button exposes data-is-muted; fall back to the aria-label
    // ("Turn on microphone" means currently off/muted).
    find() {
      const byData = document.querySelector<HTMLElement>(
        "button[data-is-muted]",
      );
      if (byData) return byData;
      return (
        [...document.querySelectorAll<HTMLElement>("button[aria-label]")].find(
          (b) => /microphone/i.test(b.getAttribute("aria-label") || ""),
        ) || null
      );
    },
    isMuted(el) {
      const dm = el.getAttribute("data-is-muted");
      if (dm != null) return dm === "true";
      return (el.getAttribute("aria-label") || "")
        .toLowerCase()
        .includes("turn on");
    },
  },
};

/** Pick the adapter for a hostname, or null if the site isn't supported. */
export function pickAdapter(hostname: string): Adapter | null {
  if (hostname.endsWith("zoom.us")) return ADAPTERS.zoom;
  if (hostname === "meet.google.com") return ADAPTERS.meet;
  return null;
}
