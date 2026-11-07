import BarcChromium

extension PageCommand {
    var nativeBrowserCommand: Int32? {
        switch self {
        case .find: Int32(BARC_PAGE_FIND.rawValue)
        case .zoomIn: Int32(BARC_PAGE_ZOOM_IN.rawValue)
        case .zoomOut: Int32(BARC_PAGE_ZOOM_OUT.rawValue)
        case .actualSize: Int32(BARC_PAGE_ZOOM_RESET.rawValue)
        case .print: Int32(BARC_PAGE_PRINT.rawValue)
        case .webInspector: Int32(BARC_PAGE_DEVTOOLS.rawValue)
        case .hardReload: Int32(BARC_PAGE_HARD_RELOAD.rawValue)
        default: nil
        }
    }

    var nativeSiteDataAction: Int32? {
        switch self {
        case .clearSiteCookies: Int32(BARC_SITE_COOKIES.rawValue)
        case .clearSiteCache: Int32(BARC_SITE_CACHE.rawValue)
        case .clearCookiesAndReload: Int32(BARC_SITE_COOKIES_AND_RELOAD.rawValue)
        default: nil
        }
    }

    var supportsNativePage: Bool {
        if nativeBrowserCommand != nil || nativeSiteDataAction != nil { return true }
        switch self {
        case .goBack, .goForward, .reload, .copyURL, .mute: return true
        default: return false
        }
    }
}

extension ChromiumPageNavigation {
    @discardableResult
    func performNativePageCommand(_ command: PageCommand,
                                  completion: @escaping @MainActor (ChromiumSiteDataOutcome) -> Void = { _ in }) -> Bool {
        if let action = command.nativeSiteDataAction {
            return clearNativeSiteData(action, completion: completion)
        }
        switch command {
        case .goBack: return goBack()
        case .goForward: return goForward()
        case .reload: return reload()
        case .mute:
            guard let muted = state.isAudioMuted else { return false }
            return setAudioMuted(!muted)
        default:
            guard let native = command.nativeBrowserCommand else { return false }
            return executeNativePageCommand(native)
        }
    }
}
