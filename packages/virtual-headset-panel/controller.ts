import { createState } from "ags";

// Panel visibility. Toggled by re-invoking the binary with `toggle` (single-
// instance argv forwarding, see app.ts) — bind that to a key — or shown
// directly on a bare launch / `ags run`.
export const [panelOpen, setPanelOpen] = createState(false);

export function togglePanel(): void {
  setPanelOpen(!panelOpen.get());
}
