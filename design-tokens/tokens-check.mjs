#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Mobile-side drift check. Regenerates mirror + Style Dictionary outputs
// and fails if the working tree differs from canonical. Catches the case
// where someone edits a token source file but forgets `make tokens`/`npm
// run tokens` before committing.
//
// Usage: npm run tokens:check (called from CI / pre-commit)

import { execSync } from "node:child_process";

const OUTPUTS = [
  "design-tokens/primitives.tokens.json",
  "android/app/src/main/kotlin/com/papercuspai/operator/mobile/theme/PapercupTokens.kt",
  "ios/Papercup/Sources/Papercup/PapercupTokens.swift",
];

try {
  execSync("npm run tokens --silent", { stdio: "inherit" });
} catch (e) {
  console.error("✗ tokens regen failed");
  process.exit(e.status || 1);
}

const diff = execSync(`git --no-pager diff --stat -- ${OUTPUTS.join(" ")}`, {
  encoding: "utf8",
});
if (diff.trim()) {
  console.error(
    "\n✗ design-token outputs drifted from sources. Run 'make tokens' (or 'npm run tokens') and commit the diff:\n",
  );
  console.error(diff);
  process.exit(1);
}

// Coverage: every source token must appear in Kotlin + Swift outputs.
try {
  execSync("node design-tokens/verify-coverage.mjs", { stdio: "inherit" });
} catch (e) {
  process.exit(e.status || 1);
}

console.log("✓ design tokens in sync");
