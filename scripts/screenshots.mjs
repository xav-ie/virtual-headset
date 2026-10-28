#!/usr/bin/env node
// The docs' screenshots, on a Mac:
//   assets/panel/<state>.png  the real macOS panel (live, muted, no-call), drawn by
//                             the app itself: `virtual-headset screenshot <dir>`
//   assets/screenshot.png     the README's hero: a mock desktop with a Zoom web call,
//                             and the real "live" panel open under the menu bar icon
// Colors come from assets/palette.json, like the diagrams.
// Run: node scripts/screenshots.mjs [path/to/virtual-headset]
//   (defaults to `nix build .#virtual-headset`; needs Google Chrome, or CHROME=…).
// Each panel state flashes in the screen's corner while it's captured. Needs
// oxipng (in the dev shell) for the final lossless optimization.
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const asset = (...p) => path.join(root, "assets", ...p);
const c = JSON.parse(readFileSync(asset("palette.json"), "utf8")).dark;
const CHROME =
  process.env.CHROME ??
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

// --- the real panel ----------------------------------------------------------------
const bin =
  process.argv[2] ??
  path.join(
    execFileSync(
      "nix",
      ["build", "--no-link", "--print-out-paths", `${root}#virtual-headset`],
      { encoding: "utf8" },
    ).trim(),
    "bin/virtual-headset",
  );
mkdirSync(asset("panel"), { recursive: true });
execFileSync(bin, ["screenshot", asset("panel")], { stdio: "inherit" });

// --- the hero ----------------------------------------------------------------------
// Only the top of a narrow desktop: the menu bar and the open panel are the
// point, so the call window keeps its size, runs off the bottom edge, and sits
// under the panel (which covers its second tile).
const W = 900,
  H = 330;
// The mic glyph, as the bar item draws it: red while live.
const mic = (color) =>
  `<svg viewBox="0 0 24 24" width="16" height="16"><rect x="8" y="2" width="8" height="13" rx="4" fill="${color}"/><path d="M5 11a7 7 0 0 0 14 0M12 18v4" fill="none" stroke="${color}" stroke-width="2" stroke-linecap="round"/></svg>`;
// Placeholder status icons for the rest of the menu bar.
const glyph = (w) => `<i style="width:${w}px"></i>`;
const people = [
  ["Ada", "#8e5cd9", true],
  ["Grace", "#1f8f6f", false],
  ["Alan", "#c26a1e", false],
  ["You", "#3d6fd6", false],
];
const tile = ([name, color, speaking]) =>
  `<div class="tile${speaking ? " speaking" : ""}"><div class="avatar" style="background:${color}">${name[0]}</div><div class="name">${name}</div></div>`;

const hero = `<!doctype html>
<html><head><meta charset="utf-8"><style>
  body { margin: 0; font-family: -apple-system, 'Segoe UI', Helvetica, Arial, sans-serif; }
  .desktop { width: ${W}px; height: ${H}px; position: relative; overflow: hidden;
             background: radial-gradient(circle at 20% 10%, #3a4157, #171a22 70%); }
  .menubar { height: 30px; background: rgba(20, 22, 28, .78); display: flex; align-items: center; gap: 18px;
             padding: 0 16px; color: ${c.text}; font-size: 13.5px; }
  .menubar b { font-weight: 650; }
  .menubar .right { margin-left: auto; display: flex; align-items: center; gap: 16px; }
  .menubar i { display: block; height: 11px; border-radius: 3px; background: ${c.muted}; opacity: .7; }
  .menubar .mic { display: grid; place-items: center; width: 30px; height: 22px; border-radius: 6px; background: rgba(255,255,255,.14); }
  .window { position: absolute; left: 36px; top: 56px; width: 820px; height: 660px; border-radius: 12px; overflow: hidden;
            background: #202124; box-shadow: 0 20px 50px rgba(0,0,0,.5);
            filter: grayscale(.9) brightness(.85); } /* backdrop: the panel's red Live stands out */
  .toolbar { height: 46px; background: #35363a; display: flex; align-items: center; gap: 8px; padding: 0 14px; }
  .toolbar span { width: 12px; height: 12px; border-radius: 50%; }
  .url { flex: 1; margin-left: 14px; height: 28px; border-radius: 14px; background: #202124; color: #e8eaed;
         display: flex; align-items: center; padding: 0 14px; font-size: 13px; }
  .grid { position: absolute; inset: 62px 16px 86px; display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
  .tile { background: #3c4043; border-radius: 10px; position: relative; display: grid; place-items: center; }
  .tile.speaking { outline: 3px solid #8ab4f8; }
  .avatar { width: 84px; height: 84px; border-radius: 50%; color: white; font-size: 38px; display: grid; place-items: center; }
  .name { position: absolute; left: 12px; bottom: 10px; color: white; font-size: 14px; }
  .controls { position: absolute; left: 0; right: 0; bottom: 22px; display: flex; justify-content: center; gap: 12px; }
  .controls span { width: 46px; height: 46px; border-radius: 50%; background: #3c4043; display: grid; place-items: center; }
  .controls span.end { width: 68px; border-radius: 23px; background: #ea4335; }
  .panel { position: absolute; top: 34px; right: 62px; width: 340px; filter: drop-shadow(0 14px 30px rgba(0,0,0,.55)); }
</style></head><body><div class="desktop">
  <div class="menubar"><b>Chrome</b><span>File</span><span>Edit</span><span>View</span>
    <div class="right">${glyph(18)}<span class="mic">${mic(c.live)}</span>${glyph(16)}${glyph(22)}<span>Tue 10:02</span></div>
  </div>
  <div class="window">
    <div class="toolbar"><span style="background:#ff5f57"></span><span style="background:#febc2e"></span><span style="background:#28c840"></span>
      <div class="url">app.zoom.us/wc/812-4471-0093</div></div>
    <div class="grid">${people.map(tile).join("")}</div>
    <div class="controls"><span>${mic("#e8eaed")}</span><span></span><span></span><span class="end"></span></div>
  </div>
  <img class="panel" src="file://${asset("panel", "live.png")}">
</div></body></html>`;

const dir = mkdtempSync(path.join(tmpdir(), "virtual-headset-hero-"));
writeFileSync(path.join(dir, "hero.html"), hero);
execFileSync(
  CHROME,
  [
    "--headless=new",
    "--disable-gpu",
    "--hide-scrollbars",
    "--allow-file-access-from-files",
    "--force-device-scale-factor=2",
    `--window-size=${W},${H}`,
    `--screenshot=${asset("screenshot.png")}`,
    `file://${path.join(dir, "hero.html")}`,
  ],
  { stdio: "ignore" },
);
// Lossless recompression, so the committed images are already as small as they get.
execFileSync(
  "oxipng",
  [
    "--opt",
    "max",
    "--strip",
    "safe",
    "--quiet",
    asset("screenshot.png"),
    ...["live", "muted", "no-call", "advanced", "keyboard"].map((s) =>
      asset("panel", `${s}.png`),
    ),
  ],
  { stdio: "inherit" },
);
console.log("Wrote and optimized assets/panel/*.png and assets/screenshot.png");
