# Licensed under GPL-3.0. See LICENSE.
"""Keep the Chromium shell's app-owned sources off the WebKit page boundary."""

import re

# Check app sources and each package's production Swift sources. The legacy
# data reader uses file URLs and never needs a WebKit page or data store.
SHELL_ROOTS = ("App", "Nook", "Navigation", "CommandPalette", "Onboarding", "UI", "Settings", "ChromiumApp")
PAGE_TYPE = re.compile(
    r"\b(?:WKWebView(?:Configuration)?|WKWebsiteDataStore|WKNavigationDelegate|WKUIDelegate|"
    r"WKScriptMessageHandler(?:WithReply)?|WebKitPageAccess|WebKitPageNavigation|"
    r"WebKitPageDelegateAdapter|WebKitWebViewProvider|WebKitProfileStorage)\b"
)
WEBKIT_IMPORT = re.compile(
    r"^\s*(?:@\w+\s+|(?:private|fileprivate|internal|package|public)\s+)*"
    r"import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?WebKit\b",
)


def shell_source_violations(root):
    violations = []
    directories = [root / directory for directory in SHELL_ROOTS]
    directories.extend(sorted((root / "Packages").glob("*/Sources")))
    for directory in directories:
        for source in sorted(directory.rglob("*.swift")):
            for number, line in enumerate(source.read_text().splitlines(), start=1):
                if line.lstrip().startswith(("//", "/*", "*")):
                    continue
                code = line.split("//", 1)[0]
                if match := WEBKIT_IMPORT.search(code) or PAGE_TYPE.search(code):
                    violations.append(f"{source.relative_to(root)}:{number}: {match[0].strip()}")
    return violations


def verify_shell_boundary(root):
    violations = shell_source_violations(root)
    if violations:
        raise ValueError("Bark shell contains WebKit page paths:\n" + "\n".join(violations))
