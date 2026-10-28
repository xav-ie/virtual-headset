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
const SIZE = { head: 19, title: 16, sub: 13.5, label: 13, axis: 12.5 };
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
// `key` marks Virtual Headset itself; `live` is the brand red of a hot mic.
const style = (c) => `<style>
  text { font-family: ${FONT}; fill: ${c.text}; }
  .bg { fill: ${c.bg}; }
  .box { fill: ${c.surface}; stroke: ${c.line}; stroke-width: 2; }
  .key { fill: ${c.live}; fill-opacity: .08; stroke: ${c.live}; stroke-width: 2.5; }
  .head { font-size: ${SIZE.head}px; font-weight: 700; }
  .lede { font-size: ${SIZE.sub + 1}px; fill: ${c.muted}; }
  .title { font-size: ${SIZE.title}px; font-weight: 650; }
  .sub { font-size: ${SIZE.sub}px; fill: ${c.muted}; }
  .label { font-size: ${SIZE.label}px; font-weight: 600; fill: ${c.text}; }
  .axis { font-size: ${SIZE.axis}px; fill: ${c.muted}; }
  .axis-strong { font-size: ${SIZE.axis}px; font-weight: 650; fill: ${c.text}; }
  .edge { fill: none; stroke: ${c.border}; stroke-width: 2; marker-end: url(#arrow); }
  .tick { stroke: ${c.muted}; stroke-width: 1.5; stroke-dasharray: 4 4; }
  .tag { fill: ${c.bg}; }
  .arrowhead { fill: ${c.border}; }
  .badge { fill: ${c.live}; }
  .badge-text { font-size: 12px; font-weight: 700; fill: #ffffff; }
  .ink { fill: none; stroke: ${c.text}; stroke-width: 2.4; stroke-linecap: round; stroke-linejoin: round; }
  .ink-live { fill: none; stroke: ${c.live}; stroke-width: 2.4; stroke-linecap: round; stroke-linejoin: round; }
  .seg-quiet { fill: ${c.surface}; stroke: ${c.line}; stroke-width: 1.5; }
  .seg-live { fill: ${c.live}; fill-opacity: .2; stroke: ${c.live}; stroke-width: 1.5; }
  .seg-ok { fill: ${c.ok}; fill-opacity: .2; stroke: ${c.ok}; stroke-width: 1.5; }
  .seg-mono { fill: ${c.border}; fill-opacity: .16; stroke: ${c.border}; stroke-width: 1.5; }
</style>`;

const svg = (h, body) =>
  ["light", "dark"].map(
    (theme) =>
      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${n(h)}" width="${W}" height="${n(h)}" role="img">` +
      `${style(palette[theme])}<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path class="arrowhead" d="M0 0L10 5L0 10z"/></marker></defs>` +
      `<rect class="bg" width="${W}" height="${n(h)}"/>${body}</svg>\n`,
  );

const text = (cls, x, y, s, anchor = "start") =>
  `<text class="${cls}" x="${n(x)}" y="${n(y)}"${anchor === "start" ? "" : ` text-anchor="${anchor}"`}>${esc(s)}</text>`;
const rect = (cls, x, y, w, h, r) =>
  `<rect class="${cls}" x="${n(x)}" y="${n(y)}" width="${n(w)}" height="${n(h)}" rx="${r}"/>`;

// The takeaway, said before the picture: a headline and one line under it.
// Returns the body and where the picture can start.
const headline = (head, lede) => ({
  body: text("head", M, 36, head) + (lede ? text("lede", M, 60, lede) : ""),
  top: lede ? 92 : 68,
});

// Glyphs, drawn in a 48×48 square centered on (x, y), so a box can show what it is.
const GLYPHS = {
  mic: "M-6 -20h12v18a6 6 0 0 1 -12 0zM-6 -20a6 6 0 0 1 12 0M-13 -4a13 13 0 0 0 26 0M0 9v11M-8 20h16",
  keyboard:
    "M-21 -12h42a4 4 0 0 1 4 4v18a4 4 0 0 1 -4 4h-42a4 4 0 0 1 -4 -4v-18a4 4 0 0 1 4 -4zM-16 -5h2M-8 -5h2M0 -5h2M8 -5h2M16 -5h2M-12 2h2M-4 2h2M4 2h2M12 2h2M-10 8h20",
  headset:
    "M-17 6v-6a17 17 0 0 1 34 0v6M-21 2h6v14h-6zM15 2h6v14h-6zM-18 16q0 8 12 8M-5 24h3",
  call: "M-23 -17h46a3 3 0 0 1 3 3v28a3 3 0 0 1 -3 3h-46a3 3 0 0 1 -3 -3v-28a3 3 0 0 1 3 -3zM-26 -9h52M-18 -3h16v8h-16zM2 -3h16v8h-16zM-18 8h16v4h-16zM2 8h16v4h-16z",
  plug: "M-7 -20v10M7 -20v10M-13 -10h26v8a13 13 0 0 1 -26 0zM0 11v10",
  puzzle:
    "M-16 -16h10a5 5 0 1 1 10 0h12v12a5 5 0 1 0 0 10v12h-12a5 5 0 1 1 -10 0h-10z",
  menubar:
    "M-24 -18h48v9h-48zM-19 -13.5h6M-9 -13.5h6M11 -13.5h3M18 -13.5h2M4 -4h20v22h-20zM8 3h12M8 10h8",
  light:
    "M0 -8a8 8 0 1 1 0 16a8 8 0 1 1 0 -16zM0 -21v6M0 15v6M-21 0h6M15 0h6M-15 -15l4 4M11 11l4 4M-15 15l4 -4M11 -11l4 -4",
  button:
    "M0 -18a18 18 0 1 1 0 36a18 18 0 1 1 0 -36zM0 -8a8 8 0 1 1 0 16a8 8 0 1 1 0 -16z",
  muted:
    "M-6 -20h12v18a6 6 0 0 1 -12 0zM-6 -20a6 6 0 0 1 12 0M-13 -4a13 13 0 0 0 26 0M0 9v11M-8 20h16M-18 -18L18 18",
};
const glyph = (name, x, y, live = false) =>
  `<path class="${live ? "ink-live" : "ink"}" transform="translate(${n(x)} ${n(y)})" d="${GLYPHS[name]}"/>`;

// A box with an optional glyph on top, a title and wrapped subtitles under it,
// all centered. kind is box (plain) or key (Virtual Headset itself).
const box = ({ x, y, w, h, icon, text: [title, ...subs], kind = "box" }) => {
  const subLines = subs.flatMap((s) => wrap(s, SIZE.sub, w - 28));
  const height =
    (icon ? 58 : 0) + SIZE.title * 1.35 + subLines.length * SIZE.sub * 1.35;
  let top = y + (h - height) / 2;
  let out = rect(kind, x, y, w, h, 14);
  if (icon) {
    out += glyph(icon, x + w / 2, top + 24, kind === "key");
    top += 58;
  }
  out += text("title", x + w / 2, top + SIZE.title, title, "middle");
  top += SIZE.title * 1.35;
  return (
    out +
    subLines
      .map((s, i) =>
        text(
          "sub",
          x + w / 2,
          top + SIZE.sub * (i + 1) * 1.35 - 4,
          s,
          "middle",
        ),
      )
      .join("")
  );
};

// A label on a line, over a background so the line doesn't run through it. A
// label can be a step, [number, text], shown with a numbered badge.
const label = (x, y, l) => {
  const [step, s] = Array.isArray(l) ? l : [null, l];
  const badge = step ? 24 : 0;
  const w = textWidth(s, SIZE.label) + 14 + badge;
  const left = x - w / 2;
  return (
    rect("tag", left, y - 12, w, 22, 6) +
    (step
      ? `<circle class="badge" cx="${n(left + 13)}" cy="${n(y - 1)}" r="9.5"/>` +
        text("badge-text", left + 13, y + 3.5, step, "middle")
      : "") +
    text("label", left + badge + 7, y + 3.5, s)
  );
};

const arrow = (points) =>
  `<path class="edge" d="M${points.map(([x, y]) => `${n(x)} ${n(y)}`).join("L")}"/>`;

// A box with a glyph and title on top and a bulleted list under them, for "any
// of these" sets.
const ITEM = 25;
const listBox = ({ x, y, w, h, icon, title, items, kind = "box" }) => {
  const height = 58 + SIZE.title * 1.35 + 10 + items.length * ITEM;
  const top = y + (h - height) / 2;
  const left = x + 34;
  return (
    rect(kind, x, y, w, h, 14) +
    glyph(icon, x + w / 2, top + 24, kind === "key") +
    text("title", x + w / 2, top + 58 + SIZE.title, title, "middle") +
    items
      .map((s, i) => {
        const yy = top + 58 + SIZE.title * 1.35 + 10 + i * ITEM + 16;
        return (
          `<circle class="badge" cx="${n(left - 12)}" cy="${n(yy - 4.5)}" r="3"/>` +
          text("sub", left, yy, s)
        );
      })
      .join("")
  );
};

// A small heading over a column of boxes, naming whose side it is.
const columnHead = (b, s) =>
  text("axis-strong", b.x + b.w / 2, b.y - 14, s, "middle");

// --- layout ---------------------------------------------------------------------------
// A grid of equal columns: cell(col, row) is a box's position, spanning `span` columns
// or `rows` rows.
const grid = ({
  cols,
  gapX,
  rowH,
  gapY = 0,
  top,
  left = M,
  width = W - 2 * M,
}) => {
  const colW = (width - gapX * (cols - 1)) / cols;
  return (col, row = 0, { span = 1, rows = 1 } = {}) => ({
    x: left + col * (colW + gapX),
    y: top + row * (rowH + gapY),
    w: colW * span + gapX * (span - 1),
    h: rowH * rows + gapY * (rows - 1),
  });
};

// Arrows between two boxes side by side, at height `y`, or else `at` (0 to 1)
// down their shared height. `both` adds a second arrow back below the first;
// labels are [there, back], placed above the first arrow and below the second.
const link = (
  a,
  b,
  { label: tags, both, at = 0.5, y: fixed, gap = 30 } = {},
) => {
  const [l, r] = a.x < b.x ? [a, b] : [b, a];
  const top = Math.max(l.y, r.y),
    bottom = Math.min(l.y + l.h, r.y + r.h);
  const y = fixed ?? top + (bottom - top) * at;
  const x1 = l.x + l.w,
    x2 = r.x,
    mid = (x1 + x2) / 2;
  const [there, back] = both ? (tags ?? []) : [tags];
  const one = (yy, forward, tag, above) =>
    arrow(
      forward
        ? [
            [x1, yy],
            [x2, yy],
          ]
        : [
            [x2, yy],
            [x1, yy],
          ],
    ) + (tag ? label(mid, above ? yy - 16 : yy + 18, tag) : "");
  const rightward = a.x < b.x;
  if (!both) return one(y, rightward, there, true);
  return (
    one(y - gap / 2, rightward, there, true) +
    one(y + gap / 2, !rightward, back, false)
  );
};

// Lanes of labeled segments over time, with dashed ticks for the moments that
// matter. A lane is [name, [[from, to, text, kind], …]] with from/to as 0 to 1; a
// tick is [at, first line, second line?].
const lanes = ({ top, rows, ticks, left = 200, h = 46, gap = 14 }) => {
  const x0 = left,
    x1 = W - M;
  const at = (t) => x0 + (x1 - x0) * t;
  const bottom = top + rows.length * (h + gap) - gap;
  return {
    h: bottom + 62,
    body:
      ticks
        .map(
          ([t]) =>
            `<line class="tick" x1="${n(at(t))}" y1="${top - 8}" x2="${n(at(t))}" y2="${bottom + 10}"/>`,
        )
        .join("") +
      ticks
        .map(
          ([t, first, second]) =>
            text("axis-strong", at(t), bottom + 30, first, "middle") +
            (second ? text("axis", at(t), bottom + 48, second, "middle") : ""),
        )
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
// Each returns { h, body, alt }. The parties that recur are defined once.
const headset = {
  icon: "headset",
  kind: "key",
  text: [
    "Virtual Headset",
    "a headset made in software: a mic and a mute button",
  ],
};
const callApp = { icon: "call", text: ["Zoom or Meet", "web or desktop"] };

const diagrams = {
  // Three lanes, one per thing that travels: your voice and your mute go to the
  // call app, and its answer comes back. Each lane reads in one direction, named
  // on the left, so no arrow needs a label.
  "how-it-works"() {
    const h = headline(
      "Zoom and Meet only obey a headset's mute button. Virtual Headset gives your mic one",
      "your call app sees an ordinary USB headset: a microphone with your voice, a mute button it listens to, and a mute light it turns on",
    );
    const gutter = 112;
    const cell = grid({
      cols: 3,
      gapX: 96,
      rowH: 118,
      gapY: 22,
      top: h.top + 30,
      left: M + gutter,
      width: W - 2 * M - gutter,
    });
    const row = (r, cells) =>
      cells.map((c, i) => ({
        ...cell(i, r),
        ...c,
        ...(i === 1 ? { kind: "key" } : {}),
      }));
    const voice = row(0, [
      { icon: "mic", text: ["Your mic", "built-in, USB or Bluetooth"] },
      {
        icon: "headset",
        text: ["Its microphone", "noise removed, if you like"],
      },
      { icon: "call", text: ["Zoom hears you", "as from any headset"] },
    ]);
    const mute = row(1, [
      {
        icon: "keyboard",
        text: ["You press mute", "a key, menu bar or panel"],
      },
      { icon: "button", text: ["Its mute button", "the one call apps obey"] },
      { icon: "muted", text: ["Zoom mutes", "as if you clicked its button"] },
    ]);
    const seen = row(2, [
      {
        icon: "menubar",
        text: ["You see muted", "in your menu bar and panel"],
      },
      { icon: "light", text: ["Its mute light", "on while you're muted"] },
      { icon: "call", text: ["Zoom turns it on", "even if you muted in Zoom"] },
    ]);
    const lanes = [
      [voice, "Your voice"],
      [mute, "Mute"],
      [seen, "What you see"],
    ];
    return {
      h: seen[0].y + seen[0].h + 24,
      body:
        h.body +
        columnHead(voice[0], "YOU") +
        columnHead(voice[1], "VIRTUAL HEADSET") +
        columnHead(voice[2], "ZOOM OR MEET") +
        lanes
          .map(([[first], name]) =>
            text("title", M, first.y + first.h / 2 + 6, name),
          )
          .join("") +
        lanes
          .flatMap(([boxes]) => boxes)
          .map(box)
          .join("") +
        link(voice[0], voice[1]) +
        link(voice[1], voice[2]) +
        link(mute[0], mute[1]) +
        link(mute[1], mute[2]) +
        link(seen[2], seen[1]) +
        link(seen[1], seen[0]),
      alt: "Zoom and Meet only obey a headset's mute button, and Virtual Headset gives your mic one: your call app sees an ordinary USB headset. Your voice: your mic (built-in, USB or Bluetooth) goes into Virtual Headset's microphone, with noise removed if you like, and Zoom hears you as from any headset. Mute: you press mute (a key, menu bar or panel), which presses Virtual Headset's mute button, the one call apps obey, and Zoom mutes as if you clicked its button. What you see: Zoom turns on Virtual Headset's mute light, even if you muted in Zoom, and you see muted in your menu bar and panel",
    };
  },

  // A hub: whatever you press, the call app decides, and everything shows its answer.
  "mute-anywhere"() {
    const h = headline(
      "Mute from anywhere, and everything agrees",
      "every mute goes to your call app, which decides, and every indicator shows what it decided",
    );
    const cell = grid({ cols: 3, gapX: 130, rowH: 236, top: h.top });
    const from = {
      ...cell(0),
      icon: "keyboard",
      title: "Press mute anywhere",
      items: [
        "a key",
        "your menu or status bar",
        "the panel",
        "the Firefox toolbar",
        "Zoom or Meet's own button",
      ],
    };
    const call = {
      ...cell(1),
      icon: "call",
      kind: "key",
      text: ["Zoom or Meet mutes", "the one place mute is decided"],
    };
    const to = {
      ...cell(2),
      icon: "muted",
      title: "It shows everywhere",
      items: [
        "your menu or status bar",
        "the panel",
        "the Firefox toolbar",
        "Zoom or Meet",
      ],
    };
    return {
      h: call.y + call.h + 24,
      body:
        h.body +
        listBox(from) +
        box(call) +
        listBox(to) +
        link(from, call, { label: "mute" }) +
        link(call, to, { label: "muted" }),
      alt: "Mute from anywhere, and everything agrees. Press mute anywhere (a key, your menu or status bar, the panel, the Firefox toolbar, or Zoom or Meet's own button), and Zoom or Meet mutes: it's the one place mute is decided. It then shows everywhere: your menu or status bar, the panel, the Firefox toolbar, and Zoom or Meet",
    };
  },

  bluetooth() {
    const h = headline(
      "Muted, you hear full stereo",
      "a Bluetooth headset only drops to call audio while your mic is open, and Virtual Headset opens it only while you're live",
    );
    const unmute = 0.22,
      mute = 0.62,
      settled = 0.8;
    const l = lanes({
      top: h.top + 8,
      rows: [
        [
          "In your call",
          [
            [0, unmute, "muted", "quiet"],
            [unmute, mute, "live", "live"],
            [mute, 1, "muted", "quiet"],
          ],
        ],
        [
          "Your mic",
          [
            [0, unmute, "off", "quiet"],
            [unmute, mute, "on", "live"],
            [mute, 1, "off", "quiet"],
          ],
        ],
        [
          "What you hear",
          [
            [0, unmute, "full stereo", "ok"],
            [unmute, settled, "call audio (mono)", "mono"],
            [settled, 1, "full stereo", "ok"],
          ],
        ],
      ],
      ticks: [
        [unmute, "you unmute", "your first word may clip"],
        [mute, "you mute"],
        [settled, "about 2 s later", "stereo is back"],
      ],
    });
    return {
      h: l.h,
      body: h.body + l.body,
      alt: "Muted, you hear full stereo: a Bluetooth headset only drops to call audio while your mic is open, and Virtual Headset opens it only while you're live. While you're muted your mic is off and you hear full stereo. When you unmute, the mic turns on and the headset switches to call audio, which is mono, and your first word may clip while it switches. When you mute, the mic turns off, and about 2 seconds later stereo is back",
    };
  },

  "firefox-bridge"() {
    const h = headline(
      "Firefox can't use headsets, so the extension presses the button for you",
      "it clicks the Zoom or Meet tab's own mic button, and tells Virtual Headset when you click it yourself",
    );
    const cell = grid({ cols: 4, gapX: 112, rowH: 160, top: h.top });
    const vh = {
      ...cell(0),
      ...headset,
      text: ["Virtual Headset", "knows whether you're muted"],
    };
    const helper = {
      ...cell(1),
      icon: "plug",
      text: ["Helper", "lets Firefox talk to Virtual Headset"],
    };
    const ext = {
      ...cell(2),
      icon: "puzzle",
      text: ["Firefox extension", "a mic in your toolbar"],
    };
    const tab = {
      ...cell(3),
      ...callApp,
      text: ["Zoom or Meet tab", "with its own mic button"],
    };
    return {
      h: tab.y + tab.h + 24,
      body:
        h.body +
        [vh, helper, ext, tab].map(box).join("") +
        link(vh, helper, { both: true }) +
        link(helper, ext, { both: true }) +
        link(ext, tab, { both: true, label: ["clicks mute", "reads mute"] }),
      alt: "Firefox can't use headsets, so the extension presses the button for you. Virtual Headset, which knows whether you're muted, talks through a helper that lets Firefox reach it to the Firefox extension, a mic in your toolbar. The extension clicks the Zoom or Meet tab's own mic button, and reads it back so Virtual Headset knows when you click it yourself",
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
