# App icon source

`operator-icon.svg` is a standalone copy of `OperatorLogoMark` (from
`papercup/apps/operator/app/_components/OperatorLogoMark.tsx`, variant `full`)
wrapped in the dark `op-chat-header-orb` background gradient. Its square canvas
is deliberately opaque: Apple applies the platform mask, and App Store icons
with transparent pixels are rejected.

`operator-icon-foreground.svg` is the same logo with **transparent** background,
sized so the content fits inside the Android adaptive-icon 72dp safe area
(66% of 432px = 286px). Used for `mipmap-*/ic_launcher_foreground.png`.

## Re-render (after editing either source)

```bash
cd docs/app-icon-source

# Android adaptive-icon foreground (transparent bg)
for entry in "mdpi:108" "hdpi:162" "xhdpi:216" "xxhdpi:324" "xxxhdpi:432"; do
  d="${entry%%:*}"; s="${entry##*:}"
  rsvg-convert -w $s -h $s operator-icon-foreground.svg -o ../../android/app/src/main/res/mipmap-$d/ic_launcher_foreground.png
done

# Android legacy icon (full baked render — orb + logo)
for entry in "mdpi:48" "hdpi:72" "xhdpi:96" "xxhdpi:144" "xxxhdpi:192"; do
  d="${entry%%:*}"; s="${entry##*:}"
  rsvg-convert -w $s -h $s operator-icon.svg -o ../../android/app/src/main/res/mipmap-$d/ic_launcher.png
  cp ../../android/app/src/main/res/mipmap-$d/ic_launcher.png ../../android/app/src/main/res/mipmap-$d/ic_launcher_round.png
done

# iOS — all entries in AppIcon.appiconset Contents.json
ICON=../../ios/Papercup/Resources/Assets.xcassets/AppIcon.appiconset
rsvg-convert -w 1024 -h 1024 operator-icon.svg -o $ICON/AppIcon-1024.png
rsvg-convert -w 40   -h 40   operator-icon.svg -o $ICON/AppIcon-20@2x.png
rsvg-convert -w 60   -h 60   operator-icon.svg -o $ICON/AppIcon-20@3x.png
rsvg-convert -w 58   -h 58   operator-icon.svg -o $ICON/AppIcon-29@2x.png
rsvg-convert -w 87   -h 87   operator-icon.svg -o $ICON/AppIcon-29@3x.png
rsvg-convert -w 80   -h 80   operator-icon.svg -o $ICON/AppIcon-40@2x.png
rsvg-convert -w 120  -h 120  operator-icon.svg -o $ICON/AppIcon-40@3x.png
rsvg-convert -w 120  -h 120  operator-icon.svg -o $ICON/AppIcon-60@2x.png
rsvg-convert -w 180  -h 180  operator-icon.svg -o $ICON/AppIcon-60@3x.png
```

Use **rsvg-convert** (`apt install librsvg2-bin` / `brew install librsvg`).
ImageMagick mangles the radial gradients + the cup mascot.
