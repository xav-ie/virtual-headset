// Background script for the Virtual Headset Bridge.
//
// Wires the pure mute Reconciler (./reconciler) to the real browser APIs:
//   - the headset / D-Bus daemon, via the native-messaging host
//     `virtual_headset_bridge`
//   - the Zoom/Meet web UI, via the content-script ports
// and exposes the toolbar button (click = toggle) and a right-click audio
// source picker.

import type {
  ContentCommand,
  ContentMessage,
  HostCommand,
  HostMessage,
  Source,
} from "./messages";
import { Reconciler } from "./reconciler";

const HOST_NAME = "virtual_headset_bridge";

// Long-lived ports to content scripts that have found a live mute control.
const contentPorts = new Set<browser.runtime.Port>();

let host: browser.runtime.Port | null = null;

// Reflect the agreed state on the toolbar icon + tooltip.
//   muted   -> gray mic with a strikethrough
//   unmuted -> red "live" mic (the mic is hot)
//   unknown -> gray idle mic (host not connected yet)
function updateAction(state: boolean | null): void {
  const icon =
    state === null
      ? "icons/mic-idle.svg"
      : state
        ? "icons/mic-muted.svg"
        : "icons/mic-live.svg";
  browser.browserAction.setIcon({ path: { 48: icon, 96: icon } });
  browser.browserAction.setTitle({
    title:
      state === null
        ? "Virtual Headset — not connected"
        : state
          ? "Microphone muted (click to unmute)"
          : "Microphone live (click to mute)",
  });
}

// Push the agreed state to every active meeting tab.
function applyToWeb(muted: boolean): void {
  const cmd: ContentCommand = { cmd: "apply", muted };
  for (const port of contentPorts) {
    try {
      port.postMessage(cmd);
    } catch {
      contentPorts.delete(port);
    }
  }
}

function sendToHost(msg: HostCommand): void {
  if (!host) return;
  try {
    host.postMessage(msg);
  } catch (e) {
    console.error("[vh] postMessage to host failed:", e);
  }
}

const reconciler = new Reconciler({
  applyToWeb,
  setHeadsetMute: (muted) => sendToHost({ type: "setMute", muted }),
  onChange: updateAction,
});

// ---------------------------------------------------------------------------
// Native-messaging host connection
// ---------------------------------------------------------------------------

function connectHost(): void {
  try {
    host = browser.runtime.connectNative(HOST_NAME);
  } catch (e) {
    console.error("[vh] failed to connect native host:", e);
    host = null;
    return;
  }

  host.onMessage.addListener((raw) => {
    const msg = raw as HostMessage;
    if (!msg || typeof msg !== "object") return;
    switch (msg.type) {
      case "state":
        reconciler.fromHeadset(!!msg.muted);
        break;
      case "sources":
        buildMenu(msg.sources);
        break;
      case "error":
        console.warn("[vh] host error:", msg.message);
        break;
      // "pong" is ignored; only used for liveness.
    }
  });

  host.onDisconnect.addListener((port) => {
    console.warn(
      "[vh] native host disconnected:",
      port.error && port.error.message,
    );
    host = null;
    reconciler.reset();
    // Reconnect with a short delay so a daemon/host restart recovers.
    setTimeout(connectHost, 2000);
  });

  // Ask for the current state + source list up front.
  sendToHost({ type: "query" });
  sendToHost({ type: "listSources" });
}

// ---------------------------------------------------------------------------
// Content-script ports
// ---------------------------------------------------------------------------

browser.runtime.onConnect.addListener((port) => {
  if (port.name !== "vh-content") return;
  contentPorts.add(port);

  port.onMessage.addListener((raw) => {
    const msg = raw as ContentMessage;
    if (!msg || typeof msg !== "object") return;
    switch (msg.type) {
      case "webState":
        reconciler.fromWeb(!!msg.muted);
        break;
      case "ready":
        // A control just appeared. If we already know the agreed state, make
        // the web UI match it (headset/daemon state persists across reloads).
        if (reconciler.state !== null) {
          const cmd: ContentCommand = { cmd: "apply", muted: reconciler.state };
          port.postMessage(cmd);
        }
        break;
    }
  });

  port.onDisconnect.addListener(() => contentPorts.delete(port));
});

// ---------------------------------------------------------------------------
// Toolbar click = toggle mute
// ---------------------------------------------------------------------------

// No default_popup in the manifest, so a click fires here. Toggle the daemon;
// the resulting MuteChanged comes back through the host and updates the icon.
browser.browserAction.onClicked.addListener(() => {
  sendToHost({ type: "toggle" });
});

// ---------------------------------------------------------------------------
// Right-click menu = audio source picker
// ---------------------------------------------------------------------------

const MENU_PARENT = "vh-source-parent";
let lastSources: Source[] = [];

// The source actually forwarded right now: the pinned one if any, else the
// system default (mirrors the daemon's get_source()).
function isActive(s: Source, anyConfigured: boolean): boolean {
  return anyConfigured ? s.configured : s.default;
}

// Rebuild the whole toolbar-button context menu from the latest source list:
// an "Audio source" submenu (radio per source, the forwarded one checked) plus
// a "Restart service" action. removeAll wipes everything, so the restart item
// is recreated here too. menus.refresh() updates the menu if it's open.
function buildMenu(sources: Source[]): void {
  lastSources = sources;
  const anyConfigured = sources.some((s) => s.configured);

  browser.menus.removeAll().then(() => {
    if (sources.length) {
      browser.menus.create({
        id: MENU_PARENT,
        title: "Audio source",
        contexts: ["browser_action"],
      });
      for (const s of sources) {
        browser.menus.create({
          id: `src:${s.name}`,
          parentId: MENU_PARENT,
          type: "radio",
          checked: isActive(s, anyConfigured),
          title: s.default
            ? `${s.description}  (system default)`
            : s.description,
          contexts: ["browser_action"],
        });
      }
      browser.menus.create({
        id: "vh-sep",
        type: "separator",
        contexts: ["browser_action"],
      });
    }
    browser.menus.create({
      id: "vh-restart",
      title: "Restart service",
      contexts: ["browser_action"],
    });
    browser.menus.refresh?.();
  });
}

browser.menus.onClicked.addListener((info) => {
  const id = String(info.menuItemId);
  if (id === "vh-restart") {
    sendToHost({ type: "restartService" });
    return;
  }
  if (!id.startsWith("src:")) return;
  const name = id.slice(4);
  const s = lastSources.find((x) => x.name === name);
  // Clicking the system-default entry follows the default (clears the pin);
  // any other entry pins that source. The host echoes an updated source list.
  if (s && s.default) sendToHost({ type: "clearSource" });
  else sendToHost({ type: "setSource", name });
});

// Create the menu immediately (just Restart until the source list arrives).
buildMenu([]);

// Refresh the list right before the menu opens, so it reflects changes made
// elsewhere (the AGS panel, the CLI). onShown/refresh are Firefox-only.
browser.menus.onShown?.addListener((info) => {
  if (info.contexts.includes("browser_action")) {
    sendToHost({ type: "listSources" });
  }
});

connectHost();
