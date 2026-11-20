# Check Chromium’s Bark branding

Use the prepared Chromium checkout, the output directory that built the
app’s SDK, and the corresponding staged or signed app. For an optimized Intel
build, for example:

```fish
set -l src /path/to/chromium/src
set -l out "$src/out/Barc-x64-official"
python3 -B Tests/ChromiumWebUIBranding/check.py "$src" "$out/gen/bark/app" \
    --app /path/to/Bark.app --allow-missing-pseudolocales
```

The check reads the generated product labels, compares the packs for the
locales the app ships, and inspects the About page’s installed Settings
scripts. With `--allow-missing-pseudolocales`, the runtime may omit a complete
ar-XB or en-XA pseudolocale family even when the outer app carries its
InfoPlist translation. All other locales and their variants must match. Base packs require
every product label. Grammatical-gender packs can omit strings that fall back
to the base locale.

To test those label rules without a Chromium checkout:

```fish
python3 -B -m unittest discover -s Tests/ChromiumWebUIBranding
```
