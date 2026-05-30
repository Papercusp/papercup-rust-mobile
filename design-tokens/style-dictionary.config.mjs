// SPDX-License-Identifier: GPL-3.0-or-later
// Style Dictionary v4 config for papercup-rust-mobile.
// Emits Compose Kotlin + SwiftUI Swift from DTCG-format token files.
//
// Inputs:  primitives.tokens.json + mobile.semantic.tokens.json + mobile.component.tokens.json
// Outputs:
//   android/.../theme/PapercupTokens.kt
//   ios/Papercup/Sources/Papercup/PapercupTokens.swift

import { globSync } from "node:fs";
import StyleDictionary from "style-dictionary";
import { preflight } from "@papercusp/token-kit";

preflight(globSync("design-tokens/*.tokens.json"));

// ─── Custom transforms ─────────────────────────────────────────────────────

// Compose Color() literal: 0xAARRGGBB.
// Style Dictionary's `color/composeColor` builtin assumes #RRGGBB only;
// our semantic tokens use 8-digit hex (e.g. #38BDF824) for pre-baked alpha.
StyleDictionary.registerTransform({
  name: "color/composeHex",
  type: "value",
  filter: (t) => t.$type === "color",
  transform: (t) => {
    const raw = String(t.$value).trim();
    const m = /^#?([0-9a-f]{6}|[0-9a-f]{8})$/i.exec(raw);
    if (!m) throw new Error(`bad color value for ${t.name}: ${raw}`);
    const hex = m[1].toUpperCase();
    const argb = hex.length === 6 ? `FF${hex}` : `${hex.slice(6, 8)}${hex.slice(0, 6)}`;
    return `Color(0x${argb})`;
  },
});

// SwiftUI Color(.sRGB, red:..., green:..., blue:..., opacity:...) literal.
// Same pre-baked-alpha contract.
StyleDictionary.registerTransform({
  name: "color/swiftUIsRGB",
  type: "value",
  filter: (t) => t.$type === "color",
  transform: (t) => {
    const raw = String(t.$value).trim();
    const m = /^#?([0-9a-f]{6}|[0-9a-f]{8})$/i.exec(raw);
    if (!m) throw new Error(`bad color value for ${t.name}: ${raw}`);
    const hex = m[1];
    const r = parseInt(hex.slice(0, 2), 16) / 255;
    const g = parseInt(hex.slice(2, 4), 16) / 255;
    const b = parseInt(hex.slice(4, 6), 16) / 255;
    const a = hex.length === 8 ? parseInt(hex.slice(6, 8), 16) / 255 : 1;
    return `Color(.sRGB, red: ${r.toFixed(4)}, green: ${g.toFixed(4)}, blue: ${b.toFixed(4)}, opacity: ${a.toFixed(4)})`;
  },
});

// PascalCase the dotted DTCG path: color.sky.400 → Sky400. For Kotlin val names.
// Strips top-level "color" prefix and digits-after-dot become a suffix.
StyleDictionary.registerTransform({
  name: "name/composeVal",
  type: "name",
  transform: (t) => {
    const parts = t.path.filter((p) => p !== "color");
    return parts
      .map((p) => p.charAt(0).toUpperCase() + p.slice(1))
      .join("")
      .replace(/-([a-z0-9])/g, (_, c) => c.toUpperCase());
  },
});

// camelCase the same path for Swift static let names.
StyleDictionary.registerTransform({
  name: "name/swiftLet",
  type: "name",
  transform: (t) => {
    const parts = t.path.filter((p) => p !== "color");
    const camel = parts
      .map((p, i) => (i === 0 ? p : p.charAt(0).toUpperCase() + p.slice(1)))
      .join("")
      .replace(/-([a-z0-9])/g, (_, c) => c.toUpperCase());
    return camel;
  },
});

// ─── Custom formats ────────────────────────────────────────────────────────

StyleDictionary.registerFormat({
  name: "compose/PapercupTokens",
  format: ({ dictionary }) => {
    const lines = [
      "// SPDX-License-Identifier: GPL-3.0-or-later",
      "// AUTO-GENERATED from design-tokens/*.tokens.json. Do not edit.",
      "// Run: pnpm tokens (or npm run tokens)",
      "package com.papercuspai.operator.mobile.theme",
      "",
      "import androidx.compose.ui.graphics.Color",
      "",
      "object PapercupTokens {",
    ];
    for (const t of dictionary.allTokens) {
      const desc = t.$description || t.description;
      if (desc) lines.push(`    /** ${desc} */`);
      lines.push(`    val ${t.name} = ${t.$value}`);
    }
    lines.push("}", "");
    return lines.join("\n");
  },
});

StyleDictionary.registerFormat({
  name: "swift/PapercupTokens",
  format: ({ dictionary }) => {
    const lines = [
      "// SPDX-License-Identifier: GPL-3.0-or-later",
      "// AUTO-GENERATED from design-tokens/*.tokens.json. Do not edit.",
      "// Run: pnpm tokens (or npm run tokens)",
      "import SwiftUI",
      "",
      "enum PapercupTokens {",
    ];
    for (const t of dictionary.allTokens) {
      const desc = t.$description || t.description;
      if (desc) lines.push(`    /// ${desc}`);
      lines.push(`    static let ${t.name} = ${t.$value}`);
    }
    lines.push("}", "");
    return lines.join("\n");
  },
});

// ─── Config ────────────────────────────────────────────────────────────────

export default {
  source: ["design-tokens/*.tokens.json"],
  platforms: {
    "compose-kotlin": {
      transforms: ["attribute/cti", "color/composeHex", "name/composeVal"],
      buildPath: "android/app/src/main/kotlin/com/papercuspai/operator/mobile/theme/",
      files: [
        {
          destination: "PapercupTokens.kt",
          format: "compose/PapercupTokens",
        },
      ],
    },
    "swift-ui": {
      transforms: ["attribute/cti", "color/swiftUIsRGB", "name/swiftLet"],
      buildPath: "ios/Papercup/Sources/Papercup/",
      files: [
        {
          destination: "PapercupTokens.swift",
          format: "swift/PapercupTokens",
        },
      ],
    },
  },
  log: {
    verbosity: "default",
    warnings: "warn",
    errors: { brokenReferences: "throw" },
  },
};
