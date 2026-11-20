import BarcChromium

extension PageCommand {
    var isZoomCommand: Bool {
        switch self {
        case .zoomIn, .zoomOut, .actualSize: true
        default: false
        }
    }

    var nativeBrowserCommand: Int32? {
        switch self {
        case .find: Int32(BARC_PAGE_FIND.rawValue)
        case .zoomIn: Int32(BARC_PAGE_ZOOM_IN.rawValue)
        case .zoomOut: Int32(BARC_PAGE_ZOOM_OUT.rawValue)
        case .actualSize: Int32(BARC_PAGE_ZOOM_RESET.rawValue)
        case .print: Int32(BARC_PAGE_PRINT.rawValue)
        case .developerConsole: Int32(BARC_PAGE_DEVTOOLS_CONSOLE.rawValue)
        case .developerNetwork: Int32(BARC_PAGE_DEVTOOLS_NETWORK.rawValue)
        case .developerPerformance: Int32(BARC_PAGE_DEVTOOLS_PERFORMANCE.rawValue)
        case .webInspector: Int32(BARC_PAGE_DEVTOOLS.rawValue)
        case .pickElement: Int32(BARC_PAGE_DEVTOOLS_INSPECT.rawValue)
        case .pictureInPicture: Int32(BARC_PAGE_VIDEO_PIP_TOGGLE.rawValue)
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
        case .goBack, .goForward, .reload, .copyURL, .copyScreenshot, .mute, .translate, .boost, .developerMode: return true
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
