import NookSettings
import NookWeb
import SwiftUI

/// The existing tab-tree sidebar only. Chromium owns the adjacent web surface;
/// constructing WindowView/WebsiteView here would reinstate WebKit hosting.
struct ChromiumSidebarShell: View {
    @ObservedObject var browserManager: BrowserManager
    let storage: ChromiumAppStorage
    let window: BrowserWindowState
    let registry: WindowRegistry
    let commandPalette: CommandPalette
    let organizer: TabOrganizerManager
    @ObservedObject var hover: HoverSidebarManager

    var body: some View {
        ZStack {
            SpacesSideBarView()
            if window.isSidebarMenuVisible {
                SidebarMenu()
            }
            CommandPaletteView()
            DialogView()
        }
            .environmentObject(browserManager)
            .environmentObject(browserManager.gradientColorManager)
            .environmentObject(hover)
            .environment(browserManager.tabs)
            .environment(storage.settings)
            .environment(\.nookSettings, storage.settings)
            .environment(\.tabActions, browserManager)
            .environment(window)
            .environment(registry)
            .environment(commandPalette)
            .environment(organizer)
            .defaultAppStorage(storage.defaults)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: window.spaceID) { _, _ in browserManager.windowSpaceChanged(window) }
    }
}
