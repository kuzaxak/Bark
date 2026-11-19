// Licensed under GPL-3.0. See LICENSE.

/// App chrome updates when a regular tab becomes selected.
@MainActor
public protocol TabEventObserver: AnyObject {
    func tabActivated(new session: PageSession, previous: PageSession?)
}
