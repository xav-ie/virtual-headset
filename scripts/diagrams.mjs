#!/usr/bin/env node
// Generates the docs' diagrams from one source of colors, assets/palette.json (a
// light and a dark theme). It writes docs/diagrams/<name>.svg (light) and
// <name>-dark.svg, and fills the marked blocks in the docs:
//   <!-- diagram:NAME --> … <!-- /diagram:NAME -->  a <picture> with the diagram and its alt text
// Every diagram is built from the same primitives and themed through CSS classes,
// so each body is written once. Run: node scripts/diagrams.mjs (in `nix develop`)
// `nix flake check` runs it too and fails if anything it writes differs from
// what's committed.
import {
  mkdirSync,
  readdirSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (file) => readFileSync(path.join(root, file), "utf8");
const write = (file, text) => writeFileSync(path.join(root, file), text);
const palette = JSON.parse(read("assets/palette.json"));
const DIR = "docs/diagrams";
const DOCS = [
  "README.md",
  ...readdirSync(path.join(root, "docs"))
    .filter((f) => f.endsWith(".md"))
    .map((f) => `docs/${f}`),
];

// --- primitives -------------------------------------------------------------------
const W = 1062;
const M = 24;
const SIZE = { title: 16, sub: 13.5, label: 13, axis: 12.5 };
const FONT = `-apple-system, 'Segoe UI', Helvetica, Arial, sans-serif`;

const esc = (s) =>
  String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const n = (v) => Math.round(v * 10) / 10;
// Deterministic text width estimates, so layout needs no browser.
const textWidth = (s, size) => s.length * size * 0.54;
// Greedy word wrap to a pixel width.
const wrap = (s, size, width) =>
  s.split(" ").reduce(
    (out, word) => {
      const last = out.at(-1);
      if (last && textWidth(`${last} ${word}`, size) > width) out.push(word);
      else out[out.length - 1] = last ? `${last} ${word}` : word;
      return out;
    },
    [""],
  );

// Themes apply through CSS classes, so every diagram body is written once.
// `key` marks Virtual Headset's own parts; `live` is the brand red of a hot mic.
const style = (c) => `<style>
  text { font-family: ${FONT}; fill: ${c.text}; }
  .bg { fill: ${c.bg}; }
  .box { fill: ${c.surface}; stroke: ${c.line}; stroke-width: 2; }
  .key { fill: ${c.live}; fill-opacity: .1; stroke: ${c.live}; stroke-width: 2.5; }
  .end { fill: ${c.border}; fill-opacity: .14; stroke: ${c.border}; stroke-width: 2; }
  .group { fill: none; stroke: ${c.muted}; stroke-width: 1.5; stroke-dasharray: 6 5; }
  .title { font-size: ${SIZE.title}px; font-weight: 650; }
  .sub { font-size: ${SIZE.sub}px; fill: ${c.muted}; }
  .label { font-size: ${SIZE.label}px; font-weight: 550; fill: ${c.border}; }
  .axis { font-size: ${SIZE.axis}px; fill: ${c.muted}; }
  .edge { fill: none; stroke: ${c.border}; stroke-width: 2; marker-end: url(#arrow); }
  .tick { stroke: ${c.muted}; stroke-width: 1.5; stroke-dasharray: 4 4; }
  .tag { fill: ${c.bg}; }
  .head { fill: ${c.border}; }
  .seg-quiet { fill: ${c.surface}; stroke: ${c.line}; stroke-width: 1.5; }
  .seg-live { fill: ${c.live}; fill-opacity: .2; stroke: ${c.live}; stroke-width: 1.5; }
  .seg-ok { fill: ${c.ok}; fill-opacity: .2; stroke: ${c.ok}; stroke-width: 1.5; }
  .seg-mono { fill: ${c.border}; fill-opacity: .16; stroke: ${c.border}; stroke-width: 1.5; }
</style>`;

const svg = (h, body) =>
  ["light", "dark"].map(
    (theme) =>
      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${n(h)}" width="${W}" height="${n(h)}" role="img">` +
      `${style(palette[theme])}<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path class="head" d="M0 0L10 5L0 10z"/></marker></defs>` +
      `<rect class="bg" width="${W}" height="${n(h)}"/>${body}</svg>\n`,
  );

const text = (cls, x, y, s, anchor = "start") =>
  `<text class="${cls}" x="${n(x)}" y="${n(y)}"${anchor === "start" ? "" : ` text-anchor="${anchor}"`}>${esc(s)}</text>`;
const rect = (cls, x, y, w, h, r) =>
  `<rect class="${cls}" x="${n(x)}" y="${n(y)}" width="${n(w)}" height="${n(h)}" rx="${r}"/>`;

// Lines of text centered on (x, y): the first as a title, the rest as subtitles.
const lines = (x, y, all) => {
  const height = all.reduce((sum, [, cls]) => sum + SIZE[cls] * 1.35, 0);
  let top = y - height / 2;
  return all
    .map(([s, cls]) => {
      top += SIZE[cls] * 1.35;
      return text(cls, x, top - SIZE[cls] * 0.35, s, "middle");
    })
    .join("");
};

// A box: kind is box (plain), key (Virtual Headset's parts) or end (where it lands).
const box = ({ x, y, w, h, text: [title, ...subs], kind = "box" }) =>
  rect(kind, x, y, w, h, 14) +
  lines(x + w / 2, y + h / 2, [
    [title, "title"],
    ...subs.flatMap((s) => wrap(s, SIZE.sub, w - 24)).map((s) => [s, "sub"]),
  ]);

// A label on a line, with a background so the line doesn't run through it.
const label = (x, y, s) => {
  const w = textWidth(s, SIZE.label) + 12;
  return (
    rect("tag", x - w / 2, y - 12, w, 19, 5) +
    text("label", x, y + 2, s, "middle")
  );
};

const arrow = (points) =>
  `<path class="edge" d="M${points.map(([x, y]) => `${n(x)} ${n(y)}`).join("L")}"/>`;

// --- layout ---------------------------------------------------------------------------
// A grid of equal columns: cell(col, row) is a box's position, spanning `span` columns
// or `rows` rows.
const grid = ({
  cols,
  gapX,
  rowH,
  gapY,
  top = 24,
  left = M,
  width = W - 2 * M,
}) => {
  const colW = (width - gapX * (cols - 1)) / cols;
  return (col, row, { span = 1, rows = 1 } = {}) => ({
    x: left + col * (colW + gapX),
    y: top + row * (rowH + gapY),
    w: colW * span + gapX * (span - 1),
    h: rowH * rows + gapY * (rows - 1),
  });
};

// An arrow between two boxes, along whichever axis separates them, at `at` (0 to 1)
// along the facing sides. `both` draws a second arrow back, side by side, each with
// its own label: [there, back].
const link = (a, b, { label: tag, both, at = 0.5 } = {}) => {
  const across = a.x + a.w <= b.x || b.x + b.w <= a.x;
  const forward = across ? a.x < b.x : a.y < b.y;
  const [from, to] = forward ? [a, b] : [b, a];
  const ends = (offset) => {
    if (across) {
      const top = Math.max(from.y, to.y),
        bottom = Math.min(from.y + from.h, to.y + to.h);
      const y = top + (bottom - top) * at + offset;
      return [
        [from.x + from.w, y],
        [to.x, y],
      ];
    }
    const lo = Math.max(from.x, to.x),
      hi = Math.min(from.x + from.w, to.x + to.w);
    const x = lo + (hi - lo) * at + offset;
    return [
      [x, from.y + from.h],
      [x, to.y],
    ];
  };
  const one = (points, s) => {
    const [p, q] = forward ? points : [points[1], points[0]];
    const mid = [(p[0] + q[0]) / 2, (p[1] + q[1]) / 2];
    return (
      arrow([p, q]) +
      (s
        ? across
          ? label(mid[0], mid[1] - 13, s)
          : label(mid[0] + textWidth(s, SIZE.label) / 2 + 14, mid[1], s)
        : "")
    );
  };
  if (!both) return one(ends(0), tag);
  const [there, back] = tag ?? [];
  const gap = across ? 20 : 26;
  // `back` runs the other way: swap direction for the second arrow.
  const reverse = (points, s) => {
    const [p, q] = forward ? [points[1], points[0]] : points;
    const mid = [(p[0] + q[0]) / 2, (p[1] + q[1]) / 2];
    return (
      arrow([p, q]) +
      (s
        ? across
          ? label(mid[0], mid[1] + 15, s)
          : label(mid[0] - textWidth(s, SIZE.label) / 2 - 14, mid[1], s)
        : "")
    );
  };
  return one(ends(-gap / 2), there) + reverse(ends(gap / 2), back);
};

// A titled dashed frame around some boxes.
const frame = (boxes, title, pad = 18) => {
  const x = Math.min(...boxes.map((b) => b.x)) - pad,
    y = Math.min(...boxes.map((b) => b.y)) - pad - 26;
  const w = Math.max(...boxes.map((b) => b.x + b.w)) + pad - x,
    h = Math.max(...boxes.map((b) => b.y + b.h)) + pad - y;
  return rect("group", x, y, w, h, 16) + text("title", x + 16, y + 24, title);
};

// Steps top to bottom, each an arrow from the last.
const steps = (
  list,
  { top = 24, h = 78, gap = 34, x = M, w = W - 2 * M } = {},
) => {
  const boxes = list.map((s, i) => ({ x, y: top + i * (h + gap), w, h, ...s }));
  return {
    h: top + list.length * (h + gap) - gap + 24,
    body:
      boxes.map(box).join("") +
      boxes
        .slice(1)
        .map((b, i) => link(boxes[i], b))
        .join(""),
  };
};

// Lanes of labeled segments over time, with dashed ticks for the moments that matter.
// A lane is [name, [[from, to, text, kind], …]] with from/to as 0 to 1.
const lanes = ({
  title,
  rows,
  ticks,
  left = 190,
  top = 58,
  h = 44,
  gap = 14,
}) => {
  const x0 = left,
    x1 = W - M;
  const at = (t) => x0 + (x1 - x0) * t;
  const bottom = top + rows.length * (h + gap) - gap;
  return {
    h: bottom + 52,
    body:
      text("title", M, 32, title) +
      ticks
        .map(
          ([t]) =>
            `<line class="tick" x1="${n(at(t))}" y1="${top - 10}" x2="${n(at(t))}" y2="${bottom + 10}"/>`,
        )
        .join("") +
      ticks
        .map(([t, s]) => text("axis", at(t), bottom + 32, s, "middle"))
        .join("") +
      rows
        .map(([name, segments], i) => {
          const y = top + i * (h + gap);
          return (
            text("title", M, y + h / 2 + 6, name) +
            segments
              .map(
                ([from, to, s, kind]) =>
                  rect(
                    `seg-${kind}`,
                    at(from) + 2,
                    y,
                    at(to) - at(from) - 4,
                    h,
                    8,
                  ) +
                  text(
                    "sub",
                    (at(from) + at(to)) / 2,
                    y + h / 2 + 5,
                    s,
                    "middle",
                  ),
              )
              .join("")
          );
        })
        .join(""),
  };
};

// --- diagrams ------------------------------------------------------------------------
// Each returns { h, body, alt }.
const diagrams = {
  "how-it-works"() {
    const cell = grid({ cols: 4, gapX: 110, rowH: 104, gapY: 64, top: 64 });
    const mic = {
      ...cell(0, 0),
      text: ["Your mic", "built-in, USB or Bluetooth"],
    };
    const you = {
      ...cell(0, 1),
      text: ["You", "a key, your status bar, the panel or the browser"],
    };
    const out = {
      ...cell(1, 0, { span: 2 }),
      kind: "key",
      text: [
        "Virtual_Headset_Microphone",
        "your mic, optionally with background noise removed",
      ],
    };
    const hid = {
      ...cell(1, 1, { span: 2 }),
      kind: "key",
      text: [
        "Virtual_Headset",
        "a USB telephony headset, as far as the call app can tell",
      ],
    };
    const call = {
      ...cell(3, 0, { rows: 2 }),
      kind: "end",
      text: [
        "Zoom or Meet",
        "web or desktop; its own mute button stays in sync with yours",
      ],
    };
    return {
      h: call.y + call.h + 24,
      body:
        frame([out, hid], "Virtual Headset") +
        [mic, you, out, hid, call].map(box).join("") +
        link(mic, out) +
        link(you, hid, { label: "mute" }) +
        link(out, call, { label: "your voice" }) +
        link(hid, call, { both: true, label: ["button press", "mute light"] }),
      alt: "Virtual Headset sits between you and the call app. Your mic (built-in, USB or Bluetooth) feeds Virtual_Headset_Microphone, your mic with background noise optionally removed, which Zoom or Meet records your voice from. Your mute key, status bar, panel or browser drive Virtual_Headset, which the call app sees as a USB telephony headset: it sends the call app a mute button press, and the call app lights its mute light back, so the call app's own mute button stays in sync with yours",
    };
  },

  "mute-round-trip"() {
    return {
      ...steps([
        {
          text: [
            "You press mute",
            "a key, your status bar, the panel or the browser toolbar",
          ],
        },
        {
          kind: "key",
          text: [
            "Virtual_Headset presses its mute button",
            "the button of a telephony headset, which Zoom and Meet obey",
          ],
        },
        {
          text: [
            "Zoom or Meet mutes",
            "exactly as if you had clicked its own mic button",
          ],
        },
        {
          kind: "key",
          text: [
            "It lights the headset's mute light",
            "and does the same when you mute inside the call app",
          ],
        },
        {
          kind: "end",
          text: [
            "Every indicator follows",
            "status bar, panel and browser icon; on macOS the real mic is also released",
          ],
        },
      ]),
      alt: "One mute, start to finish: you press mute with a key, your status bar, the panel or the browser toolbar; Virtual_Headset presses its mute button, the button of a telephony headset that Zoom and Meet obey; Zoom or Meet mutes exactly as if you had clicked its own mic button; it lights the headset's mute light, which it also does when you mute inside the call app; every indicator follows, and on macOS the real mic is also released",
    };
  },

  bluetooth() {
    const unmute = 0.22,
      mute = 0.62,
      settled = 0.8;
    return {
      ...lanes({
        title: "A Bluetooth headset on macOS during a call",
        rows: [
          [
            "Your call",
            [
              [0, unmute, "muted", "quiet"],
              [unmute, mute, "live", "live"],
              [mute, 1, "muted", "quiet"],
            ],
          ],
          [
            "Your real mic",
            [
              [0, unmute, "closed", "quiet"],
              [unmute, mute, "open", "live"],
              [mute, 1, "closed", "quiet"],
            ],
          ],
          [
            "What you hear",
            [
              [0, unmute, "stereo", "ok"],
              [unmute, settled, "hands-free: mono, 16 kHz", "mono"],
              [settled, 1, "stereo", "ok"],
            ],
          ],
        ],
        ticks: [
          [unmute, "you unmute"],
          [mute, "you mute"],
          [settled, "about 2 s later"],
        ],
      }),
      alt: "A Bluetooth headset on macOS during a call. While your call is muted your real mic is closed and you hear stereo. When you unmute, the mic opens and the headset switches to hands-free: mono, 16 kHz. When you mute again the mic closes, and about 2 seconds later macOS switches the headset back to stereo",
    };
  },

  "firefox-bridge"() {
    const cell = grid({ cols: 3, gapX: 120, rowH: 96, gapY: 72 });
    const key = { ...cell(0, 0), text: ["Mute key", "or virtual-headset-ctl"] };
    const daemon = {
      ...cell(1, 0),
      kind: "key",
      text: ["virtual-headset", "the daemon"],
    };
    const bus = {
      ...cell(2, 0),
      text: ["D-Bus", "com.github.virtual_headset"],
    };
    const bridge = {
      ...cell(2, 1),
      kind: "key",
      text: ["virtual-headset-bridge", "the native-messaging host"],
    };
    const ext = {
      ...cell(1, 1),
      kind: "key",
      text: ["Firefox extension", "toolbar mute and source menu"],
    };
    const tab = {
      ...cell(0, 1),
      kind: "end",
      text: ["Zoom or Meet tab", "its own mic button"],
    };
    return {
      h: tab.y + tab.h + 24,
      body:
        [key, daemon, bus, bridge, ext, tab].map(box).join("") +
        link(key, daemon, { label: "mute" }) +
        link(daemon, bus, {
          both: true,
          label: ["MuteChanged", "Mute, Toggle"],
        }) +
        link(bus, bridge, { both: true }) +
        link(bridge, ext, { both: true, label: ["state", "commands"] }) +
        link(ext, tab, { both: true, label: ["clicks mute", "reads state"] }),
      alt: "Firefox has no WebHID, so a bridge carries mute both ways. A mute key or virtual-headset-ctl tells the virtual-headset daemon, which announces MuteChanged on D-Bus and takes Mute and Toggle calls there. virtual-headset-bridge, the native-messaging host, relays between D-Bus and the Firefox extension, sending it the state and taking its commands. The extension clicks the Zoom or Meet tab's own mic button and reads its state back",
    };
  },

  "control-paths"() {
    const cell = grid({ cols: 3, gapX: 120, rowH: 96, gapY: 72 });
    const ctl = {
      ...cell(0, 0),
      text: ["virtual-headset-ctl", "mute, unmute, toggle-mute"],
    };
    const dev = {
      ...cell(1, 0),
      kind: "key",
      text: ["Virtual_Headset", "/dev/hidraw*"],
    };
    const daemon = {
      ...cell(2, 0),
      kind: "key",
      text: ["virtual-headset", "the daemon"],
    };
    const bus = { ...cell(2, 1), text: ["D-Bus", "MuteChanged(bool)"] };
    const bars = {
      ...cell(0, 1, { span: 2 }),
      kind: "end",
      text: [
        "Everything that shows mute",
        "Waybar, i3, Polybar, the panel and the Firefox bridge",
      ],
    };
    return {
      h: bars.y + bars.h + 24,
      body:
        [ctl, dev, daemon, bus, bars].map(box).join("") +
        link(ctl, dev, { label: "report 3" }) +
        link(dev, daemon) +
        link(daemon, bus, { label: "MuteChanged" }) +
        link(bus, bars),
      alt: "How the Linux controls connect: virtual-headset-ctl writes HID output report 3 (mute, unmute or toggle) to the Virtual_Headset device at /dev/hidraw*; the virtual-headset daemon reads it, presses the headset's mute button for the call app, and announces MuteChanged on D-Bus, which Waybar, i3, Polybar, the panel and the Firefox bridge all follow",
    };
  },
};

// --- write ---------------------------------------------------------------------------
mkdirSync(path.join(root, DIR), { recursive: true });
// Only what this script writes lives in DIR: a diagram removed here disappears there too.
for (const f of readdirSync(path.join(root, DIR)))
  if (
    !Object.keys(diagrams).some(
      (name) => f === `${name}.svg` || f === `${name}-dark.svg`,
    )
  )
    unlinkSync(path.join(root, DIR, f));
const built = Object.fromEntries(
  Object.entries(diagrams).map(([name, make]) => {
    const d = make();
    const [light, dark] = svg(d.h, d.body);
    write(`${DIR}/${name}.svg`, light);
    write(`${DIR}/${name}-dark.svg`, dark);
    return [name, d];
  }),
);

// Fills every marked block in a doc, outside code fences (so docs can show the
// markers themselves); unknown names fail loudly.
const fill = (file) => {
  const rel = path.relative(path.dirname(file), DIR);
  const block = (_, name) => {
    if (!built[name]) throw new Error(`${file}: no diagram ${name}`);
    const alt = esc(built[name].alt).replace(/"/g, "&quot;");
    return `<!-- diagram:${name} -->\n<picture>\n  <source media="(prefers-color-scheme: dark)" srcset="${rel}/${name}-dark.svg">\n  <img src="${rel}/${name}.svg" alt="${alt}">\n</picture>\n<!-- /diagram:${name} -->`;
  };
  const src = read(file)
    .split(/(^[ \t]*```[\s\S]*?^[ \t]*```)/m)
    .map((part, i) =>
      i % 2
        ? part
        : part.replace(
            /<!-- diagram:([\w-]+) -->[\s\S]*?<!-- \/diagram:\1 -->/g,
            block,
          ),
    )
    .join("");
  write(file, src);
};
DOCS.forEach(fill);

console.log(`Wrote ${Object.keys(built).length} diagrams and filled the docs`);
