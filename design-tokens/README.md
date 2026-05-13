# Mobile design tokens

Source of truth for color/dimension/typography tokens consumed by Android (Compose) and iOS (SwiftUI). DTCG-formatted (W3C Design Tokens Community Group draft), built with [Style Dictionary v4](https://styledictionary.com/).

## Files

| File | Tier | Editable? |
|---|---|---|
| `primitives.tokens.json` | Brand palette — sky/emerald/amber/rose/slate scales, ink shades | After Phase 4: **mirrored from `papercup/design-tokens/primitives.tokens.json`** — do not edit here |
| `mobile.semantic.tokens.json` | Mobile-specific semantics — `accent`, `surface`, `text-muted`, etc. References primitives via `{color.x.y}` aliases | Yes |
| `mobile.component.tokens.json` | Component-specific tokens — `primary-button-grad-top`, etc. | Yes |
| `style-dictionary.config.mjs` | SD v4 build config with custom Compose + SwiftUI transforms | Rarely |

## Generated outputs (DO NOT EDIT)

- `android/app/src/main/kotlin/com/papercuspai/operator/mobile/theme/PapercupTokens.kt`
- `ios/Papercup/Sources/Papercup/PapercupTokens.swift`

## Build

```bash
make tokens          # or: npm run tokens
```

Both `make build-android` and `make build-ios` auto-run this first.

## Editing tokens

1. Edit `mobile.semantic.tokens.json` or `mobile.component.tokens.json`
2. Run `make tokens`
3. Verify the generated Kotlin/Swift diffs look right
4. Commit both source + generated files

## DTCG quick reference

```json
{
  "color": {
    "accent":       { "$value": "{color.sky.400}", "$type": "color" },
    "accent-soft":  { "$value": "#38BDF824",       "$type": "color", "$description": "{color.sky.400} @ 0.14" }
  }
}
```

- `$value` — the value or `{path.to.token}` alias
- `$type` — DTCG type: `color | dimension | duration | fontFamily | fontWeight | number | shadow | cubicBezier`
- `$description` — free-form text; we use it to document the source semantics for pre-baked alpha values (since DTCG has no native alpha modifier)

## Why 8-digit hex for alpha?

DTCG colors carry alpha baked into the value (no separate `alpha` field). Style Dictionary v4 handles 8-digit hex (`#RRGGBBAA`) across all output formats correctly. The `$description` line carries the human-readable "{primitive} @ 0.X" so future-you remembers what generated the value.
