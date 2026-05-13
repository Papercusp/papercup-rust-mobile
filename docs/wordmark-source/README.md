# Pairing wordmark source

`wordmark.svg` is the canonical desktop logo, mirrored from
`papercup/apps/operator/public/wordmark.svg`.

## Re-render PNGs (after editing the SVG)

```bash
cd docs/wordmark-source
convert -background none -density 600 -resize 1560x510 wordmark.svg ../../android/app/src/main/res/drawable-nodpi/pairing_wordmark.png
convert -background none -density 200 -resize 520x170  wordmark.svg ../../ios/Papercup/Resources/Assets.xcassets/PairingWordmark.imageset/PairingWordmark.png
convert -background none -density 400 -resize 1040x340 wordmark.svg ../../ios/Papercup/Resources/Assets.xcassets/PairingWordmark.imageset/PairingWordmark@2x.png
convert -background none -density 600 -resize 1560x510 wordmark.svg ../../ios/Papercup/Resources/Assets.xcassets/PairingWordmark.imageset/PairingWordmark@3x.png
```
