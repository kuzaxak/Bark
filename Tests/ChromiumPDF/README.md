# Chromium PDF print preview

With a signed Bark candidate and the [signed-walk Python environment](../../CONTRIBUTING.md#run-the-signed-ui-walks), run this on an idle desktop.

```fish
set -l evidence (mktemp -d /private/tmp/bark-pdf-walk.XXXXXX)
"$HOME/Library/Caches/BarkSDK/signed-walk-python/bin/python" -B Tests/ChromiumPDF/walk.py --app build/Bark.app --output "$evidence/pdf" --verify-sdk
```

The walk serves a synthetic one-page PDF locally. It checks that Cmd+P opens a
rendered print preview attached to the PDF's window, the preview reports one
page, and Escape leaves the original document open. It never submits a print
job or saves a file through Print. Screenshots and failure diagnostics may show
printer names, so keep the evidence directory private.
