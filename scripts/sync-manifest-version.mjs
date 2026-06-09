#!/usr/bin/env node
// Propagate the changesets-managed version (root package.json) into the
// WebExtension manifest, which is the Nix package's version source of truth
// (packages/virtual-headset-firefox/default.nix reads it via lib.importJSON).
//
// Regex-replace the top-level "version" field so the manifest's formatting and
// key order are preserved. The pattern does NOT match "manifest_version" (the
// character before `version` there is `_`, not a quote) or "strict_min_version".
//
// Deliberately NOT synced: extension/package.json stays at 0.0.0 (it's only the
// npm manifest for the build tooling, like the panel package). Bumping it would
// change extension/package-lock.json, which invalidates the npmDepsHash pinned
// in tests/js-tests.nix and breaks `nix flake check`.
import { readFileSync, writeFileSync } from "node:fs";

const root = new URL("../", import.meta.url);
const { version } = JSON.parse(
  readFileSync(new URL("package.json", root), "utf8"),
);

const manifestPath = new URL("extension/static/manifest.json", root);
const before = readFileSync(manifestPath, "utf8");
const versionField = /("version":\s*")[^"]*(")/;

if (!versionField.test(before)) {
  console.error("sync: no top-level version field found in manifest.json");
  process.exit(1);
}

writeFileSync(manifestPath, before.replace(versionField, `$1${version}$2`));
console.log(`synced extension/static/manifest.json -> ${version}`);
