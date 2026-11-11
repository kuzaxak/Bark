// Licensed under GPL-3.0. See LICENSE.
// check.py compiles the shipped OrganizeTabsRequests verbatim; the organizer is a stand-in that refuses as the real one does.
import Foundation

@MainActor final class BrowserWindowState { let id = UUID(); var spaceID: UUID? = UUID() }
@MainActor final class WindowRegistry { var activeWindow: BrowserWindowState? }
@MainActor final class TabsController {}
@MainActor final class TabOrganizerManager {
    var looseTabs = 2
    var runs: [UUID] = []
    private(set) var error: String?
    func organizeTabs(in spaceID: UUID, using tabs: TabsController) async {
        runs.append(spaceID)
        error = looseTabs < 3 ? "Need at least 3 unfiled tabs to organize (found \(looseTabs))." : nil
    }
}
extension Notification.Name { static let organizeTabsRequested = Notification.Name("organizeTabsRequested") }
@MainActor final class Toasts { var shown: [String] = [] }

@main struct Main {
    @MainActor static func main() async {
        let window = BrowserWindowState(), registry = WindowRegistry(), organizer = TabOrganizerManager(), toasts = Toasts()
        registry.activeWindow = window
        let requests = OrganizeTabsRequests(window: window, registry: registry, organizer: organizer, tabs: TabsController(),
                                            notify: { toasts.shown.append($0) })
        let space = window.spaceID!
        await requests.organize(space)
        precondition(organizer.runs == [space])
        precondition(toasts.shown == ["Need at least 3 unfiled tabs to organize (found 2)."],
                     "the key on a space too small to sort says why instead of doing nothing")
        organizer.looseTabs = 6
        await requests.organize(space)
        precondition(organizer.runs == [space, space] && toasts.shown.count == 1, "a space that sorts shows no message")
        print("Organize Tabs: the key runs the organizer on the window's space and shows why it left a space alone")
    }
}
