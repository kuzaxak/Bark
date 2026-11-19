# Licensed under GPL-3.0. See LICENSE.
"""Keep the Chromium shell's app-owned sources off the WebKit page boundary."""

import re

# NookWeb still owns the legacy page adapter. Blocker and tweak policy cross
# the Chromium bridge and must stay independent of that adapter.
SHELL_ROOTS = ("App", "Nook", "Navigation", "CommandPalette", "Onboarding", "UI", "Settings", "ChromiumApp",
               "Packages/NookBlocker/Sources", "Packages/NookTweaks/Sources",
               "Packages/NookWeb/Sources/NookWeb/DevTools")
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
    for directory in SHELL_ROOTS:
        for source in sorted((root / directory).rglob("*.swift")):
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
