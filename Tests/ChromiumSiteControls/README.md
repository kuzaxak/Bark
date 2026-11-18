# Chromium site controls

Run the deterministic checks without opening a browser or using the network.

```fish
python3 -B Tests/ChromiumSiteControls/check.py
```

The optional signed walk exercises the actual **Secure** button and
certificate inspector. It needs a reachable public HTTPS site, an idle
macOS desktop, and the [signed walk environment](../../CONTRIBUTING.md#run-the-signed-ui-walks)
with Accessibility, event-posting, and Screen Recording access.

```fish
set -l evidence (mktemp -d /private/tmp/bark-site-certificate.XXXXXX)
"$HOME/Library/Caches/BarkSDK/signed-walk-python/bin/python" -B Tests/ChromiumSiteControls/walk.py --app build/Bark.app --output "$evidence/walk"
```

Use `--url` to choose another public HTTPS page that stays on its host and
serves the same certificate to both direct TLS clients. The walk verifies
the host with normal TLS trust, then compares the peer certificate's
SHA-256 fingerprint and issuer against the inspector in an isolated Bark
profile. It uses physical clicks for **Secure** and **Close**, confirms the
original page remains selected, and quits Bark. The walk does not accept
certificate exceptions or modify Keychain trust.
