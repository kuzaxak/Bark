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
profile. It opens the inspector with a physical **Secure** click, then verifies
both physical **Close** and **Cmd+W** dismiss it while keeping the original
page selected. It switches to the alternate tab and back to confirm both tabs
survive, then quits Bark. The walk does not accept
certificate exceptions or modify Keychain trust.

The cookie walk uses two disposable loopback sites in the same Bark profile.
It checks both cookies through browser requests and navigates the first page
with **Site Controls → More** open. If AppKit retains the old menu action,
activating it must leave the cookie unchanged. The walk then chooses
**Clear Cookies** from the current page's menu and checks that only the
requesting site's cookie disappears. The evidence includes the server observations and the
identity of the signed candidate.

```fish
set -l evidence (mktemp -d /private/tmp/bark-site-cookies.XXXXXX)
"$HOME/Library/Caches/BarkSDK/signed-walk-python/bin/python" -B Tests/ChromiumSiteControls/cookies_walk.py --app build/Bark.app --verify-sdk --output "$evidence/walk"
```
