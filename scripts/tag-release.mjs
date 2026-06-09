#!/usr/bin/env node
// The changesets/action "publish" command. It runs on every push to main that
// has no pending changesets, so it MUST be idempotent: create and push the
// v<version> tag only when it doesn't already exist on origin.
//
// The pushed tag triggers release.yml (sign + publish the .xpi). For that to
// work in CI, the version.yml checkout must use a PAT (RELEASE_PAT) — tags
// pushed with the default GITHUB_TOKEN do not trigger other workflows.
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";

const { version } = JSON.parse(
  readFileSync(new URL("../package.json", import.meta.url), "utf8"),
);
const tag = `v${version}`;

const existing = execSync(`git ls-remote --tags origin refs/tags/${tag}`)
  .toString()
  .trim();
if (existing) {
  console.log(`${tag} already exists on origin; nothing to release.`);
  process.exit(0);
}

execSync(`git tag -a ${tag} -m ${tag}`, { stdio: "inherit" });
execSync(`git push origin ${tag}`, { stdio: "inherit" });
// changesets/action scans publish output; this also makes the run log explicit.
console.log(`New tag: ${tag}`);
