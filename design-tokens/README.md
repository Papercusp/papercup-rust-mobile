# Mobile design tokens

Source of truth for color/dimension/typography tokens consumed by Android (Compose) and iOS (SwiftUI). DTCG-formatted (W3C Design Tokens Community Group draft), built with [Style Dictionary v4](https://styledictionary.com/).

## Files

| File | Tier | Editable? |
|---|---|---|
| `primitives.tokens.json` | Brand palette — sky/emerald/amber/gold/rose/slate. **MIRRORED from `papercup/design-tokens/primitives.tokens.json`** | No — edit the canonical source instead |
| `mobile.primitives.tokens.json` | Mobile-only primitives — `shade.*` (ink scale), `white-tint`. Not in canonical because mobile's ink runs darker than desktop's `--bg`. | Yes |
| `mobile.semantic.tokens.json` | Mobile-specific semantics — `accent`, `surface`, `text-muted`, etc. References primitives via `{color.x.y}` aliases | Yes |
| `mobile.component.tokens.json` | Component-specific tokens — `primary-button-grad-top`, etc. | Yes |
| `mirror.mjs` | Pulls `primitives.tokens.json` from `../papercup/design-tokens/`; fails on hash drift. Runs before SD codegen | Rarely |
| `style-dictionary.config.mjs` | SD v4 build config with custom Compose + SwiftUI transforms | Rarely |

## Generated outputs (DO NOT EDIT)

- `android/app/src/main/kotlin/com/papercuspai/operator/mobile/theme/PapercupTokens.kt`
- `ios/Papercup/Sources/Papercup/PapercupTokens.swift`

## Build

```bash
make tokens          # or: npm run tokens
```

Both `make build-android` and `make build-ios` auto-run this first. The pipeline is:

1. **`mirror.mjs`** — copies `../papercup/design-tokens/primitives.tokens.json` here, fails on hash drift. Set `REQUIRE_PRIMITIVES_SOURCE=1` to fail when the canonical source is missing (default: soft-skip). Set `PAPERCUP_DESIGN_TOKENS_DIR` to override the source path in CI.
2. **`style-dictionary build`** — emits `PapercupTokens.{kt,swift}`

## Editing the brand palette

The brand palette is **canonical in `papercup/design-tokens/primitives.tokens.json`**. To retune a brand color (e.g., shift `accent` from sky-400 to sky-500):

1. Edit `papercup/design-tokens/primitives.tokens.json` (or `desktop.semantic.tokens.json` for an alias)
2. Run `pnpm tokens` in `papercup/` — regenerates desktop CSS
3. Run `make tokens` in `papercup-rust-mobile/` — pulls the new primitives + regenerates mobile Kotlin/Swift
4. Commit both repos

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
