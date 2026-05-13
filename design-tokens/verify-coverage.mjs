#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Coverage check: every token in the JSON sources must appear in the
// generated Kotlin + Swift files. Catches the SD-filter-drop case where
// a token silently doesn't emit (e.g., a name collision between semantic
// and primitive groups). Run alongside `tokens:check` in CI.

import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

const SOURCES = [
  "design-tokens/primitives.tokens.json",
  "design-tokens/mobile.primitives.tokens.json",
  "design-tokens/mobile.semantic.tokens.json",
  "design-tokens/mobile.component.tokens.json",
];

const KOTLIN = "android/app/src/main/kotlin/com/papercuspai/operator/mobile/theme/PapercupTokens.kt";
const SWIFT = "ios/Papercup/Sources/Papercup/PapercupTokens.swift";

function flatten(obj, prefix = []) {
  const out = [];
  if (obj == null || typeof obj !== "object") return out;
  if ("$value" in obj) return [{ path: prefix, value: obj.$value, type: obj.$type }];
  for (const [k, v] of Object.entries(obj)) {
    if (k.startsWith("$") || k.startsWith("_")) continue;
    out.push(...flatten(v, [...prefix, k]));
  }
  return out;
}

function pathToCamel(parts) {
  // Drop leading "color"/"radius"/"size" group, then camelize the rest.
  // color.sky.400 -> sky400; color.accent -> accent; color.accent-soft -> accentSoft
  const dropFirst = ["color", "radius", "size"].includes(parts[0]) ? parts.slice(1) : parts;
  return dropFirst
    .map((p, i) => {
      // Hyphenated parts: each segment becomes Pascal except first
      const segs = p.split("-");
      return segs
        .map((s, j) => (i === 0 && j === 0 ? s : s[0].toUpperCase() + s.slice(1)))
        .join("");
    })
    .join("");
}

const allTokens = [];
for (const src of SOURCES) {
  const json = JSON.parse(readFileSync(join(ROOT, src), "utf8"));
  for (const tok of flatten(json)) {
    allTokens.push({ source: src, name: pathToCamel(tok.path), type: tok.type });
  }
}

const kotlin = readFileSync(join(ROOT, KOTLIN), "utf8");
const swift = readFileSync(join(ROOT, SWIFT), "utf8");

const missingKotlin = [];
const missingSwift = [];

for (const tok of allTokens) {
  // Kotlin emits as `val Name = ...` with PascalCase; Swift emits `static let name = ...` with camelCase.
  const camel = tok.name;
  const pascal = camel[0].toUpperCase() + camel.slice(1);
  if (!new RegExp(`\\b${pascal}\\b`).test(kotlin)) missingKotlin.push(camel);
  if (!new RegExp(`\\b${camel}\\b`).test(swift)) missingSwift.push(camel);
}

if (missingKotlin.length || missingSwift.length) {
  console.error("✗ token coverage gap detected");
  if (missingKotlin.length) console.error("  Kotlin missing:", missingKotlin.join(", "));
  if (missingSwift.length) console.error("  Swift missing:", missingSwift.join(", "));
  process.exit(1);
}
console.log(`✓ all ${allTokens.length} tokens covered in Kotlin + Swift`);
