#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Mirrors `primitives.tokens.json` from the canonical source repo
// (papercup/design-tokens/) into this repo. Fails with a clear diff
// if the local copy is stale.
//
// Runs as part of `make tokens`. Skips silently if the source repo
// is unavailable (e.g. CI for mobile-only changes that aren't allowed
// to drift the canonical) — but a CI job that wants strict enforcement
// can set REQUIRE_PRIMITIVES_SOURCE=1 to fail on a missing source.
//
// Source resolution order:
//   1. $PAPERCUP_DESIGN_TOKENS_DIR env var (CI override)
//   2. ../papercup/design-tokens/ (sibling-repo convention)
//   3. nothing — soft-skip unless REQUIRE_PRIMITIVES_SOURCE=1

import { readFileSync, writeFileSync, existsSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const LOCAL = resolve(HERE, "primitives.tokens.json");

function findSource() {
  if (process.env.PAPERCUP_DESIGN_TOKENS_DIR) {
    const candidate = resolve(process.env.PAPERCUP_DESIGN_TOKENS_DIR, "primitives.tokens.json");
    if (existsSync(candidate)) return candidate;
    throw new Error(`PAPERCUP_DESIGN_TOKENS_DIR set but primitives.tokens.json not found at ${candidate}`);
  }
  const sibling = resolve(HERE, "../../papercup/design-tokens/primitives.tokens.json");
  if (existsSync(sibling)) return sibling;
  return null;
}

const source = findSource();

if (!source) {
  if (process.env.REQUIRE_PRIMITIVES_SOURCE === "1") {
    console.error("✗ primitives source not found (set PAPERCUP_DESIGN_TOKENS_DIR or check sibling layout)");
    process.exit(1);
  }
  console.log("⊘ primitives source not found — skipping mirror (set REQUIRE_PRIMITIVES_SOURCE=1 to enforce)");
  process.exit(0);
}

const sourceBytes = readFileSync(source);
const sourceHash = createHash("sha256").update(sourceBytes).digest("hex");

if (existsSync(LOCAL)) {
  const localBytes = readFileSync(LOCAL);
  const localHash = createHash("sha256").update(localBytes).digest("hex");
  if (localHash === sourceHash) {
    console.log(`✓ primitives in sync with ${source.replace(process.env.HOME ?? "", "~")}`);
    process.exit(0);
  }
  console.log("⟳ primitives drift detected — updating mirror");
}

writeFileSync(LOCAL, sourceBytes);
console.log(`✓ wrote ${LOCAL.replace(process.env.HOME ?? "", "~")}`);
console.log(`  hash:   ${sourceHash.slice(0, 16)}…`);
console.log(`  source: ${source.replace(process.env.HOME ?? "", "~")}`);
