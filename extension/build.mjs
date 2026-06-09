// Local dev build: type-erase + bundle the TypeScript sources and assemble a
// loadable extension under dist/ (static assets + compiled JS).
//
// The Nix package (../packages/virtual-headset-firefox) performs the same
// steps with the esbuild CLI so it doesn't depend on npm. Keep the esbuild
// flags here in sync with that derivation.
import { build } from "esbuild";
import { cpSync, rmSync } from "node:fs";

const watch = process.argv.includes("--watch");

rmSync("dist", { recursive: true, force: true });
cpSync("static", "dist", { recursive: true });

await build({
  entryPoints: ["src/background.ts", "src/content.ts"],
  bundle: true,
  format: "iife",
  target: ["firefox115"],
  outdir: "dist",
  logLevel: "info",
});

console.log("Built extension into ./dist");
if (watch) {
  // build() with watch is deprecated; for dev just re-run. Kept minimal.
  console.log("(re-run `npm run build` after changes)");
}
