// Content script: reads and drives the mute control of the Zoom / Google Meet
// web UI, and relays state to/from the background reconciler.
//
// Browsers don't expose the virtual HID headset to the page, so the only way
// to mute the web app from a hardware/keyboard mute is to operate its own
// button. The site-specific bits live in ./adapters (and are unit-tested);
// this file is the browser wiring around them.

import type { ContentCommand, ContentMessage } from "./messages";
import { pickAdapter } from "./adapters";

(() => {
  const adapter = pickAdapter(location.hostname);
  if (!adapter) return;

  let port: browser.runtime.Port | null = null;
  let observer: MutationObserver | null = null;
  let lastReported: boolean | null = null; // last muted state we sent

  function connect(): void {
    if (port) return;
    port = browser.runtime.connect({ name: "vh-content" });
    port.onMessage.addListener((raw) => {
      const msg = raw as ContentCommand;
      if (msg && msg.cmd === "apply") applyMute(!!msg.muted);
    });
    port.onDisconnect.addListener(() => {
      port = null;
    });
    send({ type: "ready" });
    report(true);
  }

  function send(msg: ContentMessage): void {
    if (port) port.postMessage(msg);
  }

  // Click the button only if the current visible state differs from target,
  // so applying an already-correct state is a no-op (and won't echo).
  function applyMute(target: boolean): void {
    const el = adapter!.find();
    if (!el) return;
    if (adapter!.isMuted(el) !== target) {
      el.click();
    }
  }

  // Read current state and, if it changed (or forced), tell the background.
  function report(force: boolean): void {
    const el = adapter!.find();
    if (!el) return;
    const muted = adapter!.isMuted(el);
    if (!force && muted === lastReported) return;
    lastReported = muted;
    send({ type: "webState", muted });
  }

  // Watch the whole document: the mic button is re-rendered across join/leave,
  // and its label/attributes flip on mute changes. A document-level observer
  // is heavier but robust to Zoom/Meet swapping nodes underneath us.
  function startObserving(): void {
    if (observer) return;
    observer = new MutationObserver(() => {
      const el = adapter!.find();
      if (el && !port) connect();
      if (el) report(false);
    });
    observer.observe(document.documentElement, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ["aria-label", "data-is-muted"],
    });
  }

  // Kick things off: if the control is already present, connect now; either
  // way the observer will connect once it appears.
  if (adapter.find()) connect();
  startObserving();
})();
