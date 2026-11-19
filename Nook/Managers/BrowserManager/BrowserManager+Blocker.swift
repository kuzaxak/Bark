// Licensed under GPL-3.0. See LICENSE.

import NookBlocker
import NookWeb

extension BrowserManager: ContentBlockerHost {
    public var blockablePages: [any BlockablePage] { tabs.sessions }
}
