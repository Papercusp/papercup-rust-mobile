// SPDX-License-Identifier: GPL-3.0-or-later
//
// Preflight checks for design-token sources. Runs before Style Dictionary.
// Catches the SD v4 footguns we hit during the migration with clear errors
// instead of silent "No tokens" failures or wrong-output emissions.
//
// Guards:
//   1. Zero-token source file — SD v4 refuses to emit ANY output when any
//      source file has zero post-filter tokens. We reject empty sources up front.
//   2. Tree-merge collision — a semantic token can't share a path with a
//      primitive group at the same depth (e.g. `color.gold` semantic vs
//      `color.gold.400` primitive). SD's transform pipeline silently skips
//      parents-with-children. We detect and reject.
//   3. Forbidden DTCG-collision keys — `$schema` and `_meta`/`_doc` at root
//      across multiple sources cause noisy collision warnings + token-tree
//      ambiguity. We allow them in one source file only.

import { readFileSync } from "node:fs";

function hasTokens(node) {
  if (!node || typeof node !== "object") return false;
  if ("$value" in node) return true;
  for (const k of Object.keys(node)) {
    if (k.startsWith("$") || k.startsWith("_")) continue;
    if (hasTokens(node[k])) return true;
  }
  return false;
}

function walkTokens(node, pathParts, out) {
  if (!node || typeof node !== "object") return;
  if ("$value" in node) {
    out.push({ path: pathParts.join("."), hasChildren: Object.keys(node).some((k) => !k.startsWith("$") && !k.startsWith("_")) });
  }
  for (const k of Object.keys(node)) {
    if (k.startsWith("$") || k.startsWith("_")) continue;
    walkTokens(node[k], [...pathParts, k], out);
  }
}

export function preflight(sourceFiles) {
  const errors = [];
  const seenRootKeys = new Map(); // key → first file that had it

  for (const f of sourceFiles) {
    let json;
    try {
      json = JSON.parse(readFileSync(f, "utf8"));
    } catch (e) {
      errors.push(`${f}: invalid JSON — ${e.message}`);
      continue;
    }

    // Guard 1: file must contain at least one $value somewhere
    if (!hasTokens(json)) {
      errors.push(`${f}: source file has zero tokens. SD v4 will refuse to emit ANY output across all platforms. Add at least one token or delete the file.`);
      continue;
    }

    // Guard 2: detect parent-with-children-and-$value tokens (tree-merge collision)
    const tokens = [];
    walkTokens(json, [], tokens);
    for (const t of tokens) {
      if (t.hasChildren) {
        errors.push(`${f}: token at "${t.path}" has both \`$value\` and child tokens. SD v4 silently skips transforms on such parents. Rename one side so they don't share a path.`);
      }
    }

    // Guard 3: $schema and _meta-style keys must live in only one file
    for (const k of Object.keys(json)) {
      if (k === "$schema" || k.startsWith("_")) {
        const prev = seenRootKeys.get(k);
        if (prev && prev !== f) {
          errors.push(`${f}: root key "${k}" also present in ${prev}. SD v4 raises a collision warning and can produce wrong-looking output. Keep this key in one source file only.`);
        } else {
          seenRootKeys.set(k, f);
        }
      }
    }
  }

  if (errors.length) {
    console.error("✗ design-tokens preflight failed:");
    for (const e of errors) console.error("  " + e);
    process.exit(1);
  }
  console.log(`✓ preflight clean (${sourceFiles.length} source file(s))`);
}
