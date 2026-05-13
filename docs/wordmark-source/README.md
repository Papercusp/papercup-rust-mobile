# Pairing wordmark source

`wordmark.svg` is the canonical desktop logo, mirrored from
`papercup/apps/operator/public/wordmark.svg`.

## Re-render PNGs (after editing the SVG)

Use **rsvg-convert** (`apt install librsvg2-bin` on Ubuntu, `brew install
librsvg` on macOS). ImageMagick's internal SVG renderer mangles the radial
gradients + nested transforms in this file and produces the wrong cup mascot.

```bash
cd docs/wordmark-source
rsvg-convert -w 1560 -h 510 wordmark.svg -o ../../android/app/src/main/res/drawable-nodpi/pairing_wordmark.png
rsvg-convert -w  520 -h 170 wordmark.svg -o ../../ios/Papercup/Resources/Assets.xcassets/PairingWordmark.imageset/PairingWordmark.png
rsvg-convert -w 1040 -h 340 wordmark.svg -o ../../ios/Papercup/Resources/Assets.xcassets/PairingWordmark.imageset/PairingWordmark@2x.png
rsvg-convert -w 1560 -h 510 wordmark.svg -o ../../ios/Papercup/Resources/Assets.xcassets/PairingWordmark.imageset/PairingWordmark@3x.png
```
