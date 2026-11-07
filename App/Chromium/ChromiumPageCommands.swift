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
        default: nil
        }
    }

    var supportsNativePage: Bool {
        if nativeBrowserCommand != nil { return true }
        switch self {
        case .goBack, .goForward, .reload, .copyURL, .mute: return true
        default: return false
        }
    }
}

extension ChromiumPageNavigation {
    @discardableResult
    func performNativePageCommand(_ command: PageCommand) -> Bool {
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
