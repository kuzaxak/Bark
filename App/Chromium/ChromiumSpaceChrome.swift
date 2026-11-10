import Foundation
import NookTabsCore

/// What a window's chrome shows for its space.
struct ChromiumSpaceChrome: Equatable {
    let theme: SpaceTheme?
    let accentHex: String?
    let tintsPrivate: Bool
    let showsAgentGradient: Bool

    init(isIncognito: Bool, draftTheme: SpaceTheme?, spaceID: UUID?, agentSpaceID: UUID?,
         spaceTheme: SpaceTheme?, spaceAccentHex: String?) {
        tintsPrivate = isIncognito
        guard !isIncognito else {
            theme = nil; accentHex = nil; showsAgentGradient = false
            return
        }
        let isAgent = spaceID != nil && spaceID == agentSpaceID
        theme = draftTheme ?? (isAgent ? nil : spaceTheme)
        accentHex = spaceAccentHex
        showsAgentGradient = isAgent && draftTheme == nil
    }
}
