// Licensed under GPL-3.0. See LICENSE.
//
//  URLBarView.swift
//  Nook
//
//  Created by Maciek Bagiński on 28/07/2025.
//

import SwiftUI
import AppKit
import NookDesign
import NookWeb
import NookUI
import NookSettings

struct URLBarView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @EnvironmentObject private var hoverManager: HoverSidebarManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.nookSettings) var nookSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chromiumSiteControlsAnchor) private var siteControlsAnchor
    @Environment(\.chromiumExtensionActions) private var nativeExtensions
    @State private var isHovering: Bool = false
    @State private var showCheckmark: Bool = false
    @State private var isEditing = false
    @State private var addressText = ""
    @State private var selectedSuggestion: SearchManager.SearchSuggestion?
    @State private var prefilledAddress = ""
    @State private var searchManager = SearchManager()
    @FocusState private var addressFocused: Bool
    var isSidebarHovered: Bool
    var splitItemID: UUID? = nil
    var nativeTopBar: Bool = false
    private var usesNativeEditor: Bool { nativeTopBar || (browserManager.engine == .chromium && splitItemID == nil) }
    @State private var nativeEditPage: PageSession?
    @State private var nativeEditTarget: AddressEditTarget?

    var body: some View {
        addressPresentation
        .onChange(of: addressText) { _, value in
            guard isEditing else { return }
            selectedSuggestion = nil
            guard value != prefilledAddress else {
                searchManager.clearSuggestions()
                return
            }
            searchManager.searchSuggestions(for: value, includeWebSuggestions: !isLikelyURL(value))
        }
        .onChange(of: searchManager.suggestions) { _, _ in
            if let selectedSuggestion, !inlineSuggestions.contains(selectedSuggestion) {
                self.selectedSuggestion = nil
            }
        }
        .onChange(of: addressFocused) { _, focused in
            if splitItemID == nil, !focused {
                // Let a suggestion button's click finish before removing its overlay.
                DispatchQueue.main.async {
                    if !addressFocused { cancelEditing() }
                }
            }
        }
        .onChange(of: windowState.selectedItemID) { _, _ in cancelEditing() }
        .onChange(of: usesNativeEditor ? browserManager.frontPage(in: windowState)?.itemID : nil) { _, _ in cancelEditing() }
        .onChange(of: windowState.split) { _, split in
            if let splitItemID, split?.contains(splitItemID) != true {
                cancelEditing()
            }
        }
        .onChange(of: windowState.spaceID) { _, _ in cancelEditing() }
        .onChange(of: nativeEditTarget?.isCurrent) { _, current in
            if current == false { cancelEditing() }
        }
        .onChange(of: windowState.commandPalette?.isVisible) { _, visible in
            if visible == true && windowState.commandPalette?.addressEdit == nil { cancelEditing() }
        }
        .onChange(of: windowState.commandPalette?.visibleAddressEditID) { _, request in
            guard request != nil, usesNativeEditor, nativeAddressIsAvailable,
                  let palette = windowState.commandPalette, let target = palette.addressEdit else { return }
            palette.close()
            guard target.isCurrent else { return }
            if !nativeTopBar, !windowState.isSidebarVisible { hoverManager.isOverlayVisible = true }
            beginEditing(target.address, target: target)
        }
        .onDisappear { cancelEditing() }
        .onHoverTracking { hovering in
            withAnimation(NookDesign.Motion.quick) {
                isHovering = hovering
            }
        }
        
    }
    
    @ViewBuilder
    private var addressPresentation: some View {
        let session = usesNativeEditor ? browserManager.frontPage(in: windowState)
            : (splitItemID == nil ? browserManager.tabs.selectedSession(in: windowState)
               : splitItemID.flatMap { browserManager.tabs.session(for: $0) })
        collapsedAddress(session: session)
        .frame(maxWidth: .infinity, minHeight: controlHeight, maxHeight: controlHeight)
        .overlay(alignment: .bottom) {
            NativePageLoadingBar(isLoading: session?.isLoading == true, progress: session?.loadProgress)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(splitItemID == nil ? Self.fieldFill(dark: colorScheme == .dark, hovering: isHovering) : .clear)
        }
        // Report the frame in the window space so we can overlay the mini palette above all content
        .background {
            if splitItemID == nil {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: URLBarFramePreferenceKey.self,
                        value: proxy.frame(in: .named("WindowSpace"))
                    )
                }
            }
        }
        .overlay(alignment: nookSettings.sidebarPosition == .right ? .topTrailing : .topLeading) {
            if isEditing, splitItemID == nil, !usesNativeEditor {
                expandedAddressPanel
                    .frame(width: expandedPanelWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(AddressOutsideClickRegion(onOutsideClick: cancelEditing))
            }
        }
        .background {
            if isEditing, splitItemID != nil || usesNativeEditor {
                AddressAnchoredPanel(width: expandedPanelWidth, canPresent: { nativeWindow in
                    browserManager.engine != .chromium ||
                        (windowState.window === nativeWindow && browserManager.windowRegistry?.windows[windowState.id] === windowState)
                }, onRetire: cancelEditing) {
                    expandedAddressPanel
                        .frame(width: expandedPanelWidth)
                        .fixedSize(horizontal: false, vertical: true)
                        .environment(\.colorScheme, colorScheme)
                        .background(AddressOutsideClickRegion(onOutsideClick: cancelEditing))
                }
            }
        }
        .zIndex(isEditing ? 100 : 0)
    }

    @ViewBuilder
    private func collapsedAddress(session: PageSession?) -> some View {
        ZStack {
            if let splitItemID, let item = browserManager.tabs.item(splitItemID) {
                HStack(spacing: NookDesign.Spacing.sm) {
                    ItemFavicon(session: session)
                        .frame(width: NookDesign.Size.favicon, height: NookDesign.Size.favicon)
                        .clipShape(NookDesign.Radius.shape(NookDesign.Radius.xs))
                    Text(browserManager.tabs.title(for: item))
                        .font(NookDesign.Font.secondary)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, NookDesign.Spacing.rowPadding)
                .frame(height: NookDesign.Size.navRow)
                .contentShape(Rectangle())
                .pointerStyle(.horizontalText)
                .onTapGesture {
                    guard !isEditing else { return }
                    beginEditing(session?.url.absoluteString ?? item.url?.absoluteString ?? "")
                }
                .modifier(AddressActivationAccessibility(enabled: !isEditing) {
                    beginEditing(session?.url.absoluteString ?? item.url?.absoluteString ?? "")
                })
                .help("Search or Enter URL...")
                .nookFloatingSurface(in: NookDesign.Radius.shape(NookDesign.Radius.md))
            } else {
                sidebarAddress(session: session)
            }
        }
    }

    private func sidebarAddress(session: PageSession?) -> some View {
        HStack(spacing: NookDesign.Spacing.xs) {
                // The address edits in place; the global command palette remains separate.
                Group {
                    if session != nil {
                        HStack(spacing: NookDesign.Spacing.xs) {
                            // HTTPS is the norm, so only a page that is not gets a mark.
                            if isInsecure(for: session) {
                                Image(systemName: "lock.open.fill")
                                    .font(.system(size: NookDesign.Size.rowGlyph, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                if showsDeveloperAddress, let session {
                                    Text(session.url.absoluteString)
                                        .font(NookDesign.Font.mono)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                } else {
                                    // Keep the end of the host when the available width is small.
                                    HStack(spacing: 0) {
                                        Text(displayHost(for: session)).foregroundStyle(.secondary)
                                            .truncationMode(.head)
                                            .layoutPriority(1)
                                        Text(displayPath(for: session)).foregroundStyle(.tertiary)
                                            .truncationMode(.tail)
                                    }
                                    .font(NookDesign.Font.bodyRegular)
                                    .lineLimit(1)
                                }
                                if let session, session.translationOffer != nil, !session.isTranslated {
                                    Button("Translation Available") { session.toggleTranslation() }
                                        .buttonStyle(.plain)
                                        .font(NookDesign.Font.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .pointerStyle(.link)
                                        .help(browserManager.help("Translate Page", shortcut: .translatePage))
                                }
                            }
                        }
                    } else {
                        HStack(spacing: NookDesign.Spacing.xs) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: NookDesign.Size.rowGlyph, weight: .medium))
                                .foregroundStyle(textColor)
                            Text("Search or Enter URL...")
                                .font(NookDesign.Font.bodyRegular)
                                .foregroundStyle(textColor)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .pointerStyle(.horizontalText)
                .onTapGesture {
                    guard !isEditing else { return }
                    beginEditing(session?.url.absoluteString ?? "")
                }
                .modifier(AddressActivationAccessibility(enabled: !isEditing) {
                    beginEditing(session?.url.absoluteString ?? "")
                })
                .modifier(RenewedWhenSidebarShows())

                // Copy link button (show on hover when tab is selected)
                if !isEditing, isHovering, let session {
                    Button("Copy URL", systemImage: showCheckmark ? "checkmark" : "link") {
                        if usesNativeEditor {
                            guard let nativeWindow = windowState.window, nativeWindow === NSApp.keyWindow,
                                  browserManager.frontPage(in: windowState) === session,
                                  let navigation = session.navigation,
                                  browserManager.tabs.nativePageHost?.isNativeSelection(navigation, in: windowState) == true else { return }
                        }
                        copyURLToClipboard(session.url.absoluteString)
                    }
                    .help(browserManager.help("Copy URL", shortcut: .copyCurrentURL))
                    .labelStyle(.iconOnly)
                    .font(.system(size: NookDesign.Size.addressGlyph, weight: .regular))
                    .buttonStyle(NookIconButtonStyle(size: NookDesign.Size.addressButton, radius: NookDesign.Radius.sm, foreground: .secondary))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .contentTransition(.symbolEffect(.replace))
                }

                // Pinned extension buttons + library button
                if !isEditing, browserManager.engine == .chromium {
                    if nativeAddressIsAvailable, let nativeExtensions,
                       let session, session === browserManager.frontPage(in: windowState) {
                        ChromiumPinnedExtensionActions(actions: nativeExtensions)
                    }
                    let shown = nativeTopBar || isHovering || windowState.isExtensionLibraryVisible
                    ExtensionLibraryButton()
                        .disabled(session == nil)
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(shown)
                        .background { if let siteControlsAnchor { ChromiumSiteControlsButtonProbe(anchor: siteControlsAnchor) } }
                }
            }
            .padding(.leading, NookDesign.Spacing.lg)
            .padding(.trailing, NookDesign.Spacing.sm)
    }

    private var showsDeveloperAddress: Bool {
        nativeTopBar && browserManager.showsDeveloperBar(in: windowState)
    }

    private var controlHeight: CGFloat {
        if nativeTopBar { return TopBarMetrics.height - 2 * TopBarMetrics.verticalPadding }
        return splitItemID == nil ? NookDesign.Size.chromeControl : NookDesign.Size.navRow
    }

    private var nativeAddressIsAvailable: Bool {
        let host = browserManager.tabs.nativePageHost as? ChromiumNativePageHost
        return host?.isPageFullscreen(in: windowState) != true &&
            nativeTopBar == browserManager.showsTopBar(in: windowState) &&
            (nativeTopBar || (windowState.spaceDraftTheme == nil && !windowState.isSidebarAIChatVisible))
    }

    private var isComposingAddress: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
    }

    private var inlineSuggestions: [SearchManager.SearchSuggestion] {
        let typed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty || addressText == prefilledAddress { return initialLocalSuggestions }
        let primary = SearchManager.SearchSuggestion(text: typed, type: isLikelyURL(typed) ? .url : .search)
        let found = searchManager.suggestions.filter { suggestion in
            if case .folder = suggestion.type { return true }
            return suggestion.text.caseInsensitiveCompare(typed) != .orderedSame
        }
        return [primary] + found.prefix(5)
    }

    private var selectedSuggestionIndex: Int {
        guard let selectedSuggestion else { return showsInitialSuggestions ? -1 : 0 }
        return inlineSuggestions.firstIndex(of: selectedSuggestion) ?? (showsInitialSuggestions ? -1 : 0)
    }

    private func moveSuggestionSelection(by direction: Int) {
        let suggestions = inlineSuggestions
        guard !suggestions.isEmpty else { return }
        let index = min(suggestions.count - 1, max(showsInitialSuggestions ? -1 : 0, selectedSuggestionIndex + direction))
        selectedSuggestion = index < 0 || (!showsInitialSuggestions && index == 0) ? nil : suggestions[index]
    }

    @ViewBuilder
    private var inlineAddressField: some View {
        if splitItemID != nil || usesNativeEditor {
            SplitAddressSearchField(text: $addressText,
                                    onSubmit: { submitAddress() },
                                    onCancel: cancelEditing,
                                    onMove: moveSuggestionSelection,
                                    onEndEditing: cancelEditing)
                .frame(height: 22)
        } else {
            TextField("Search or Enter URL...", text: $addressText)
                .textFieldStyle(.plain)
                .font(NookDesign.Font.secondary)
                .focused($addressFocused)
                .onSubmit { submitAddress() }
                .onExitCommand { cancelEditing() }
                .onKeyPress(.downArrow) {
                    guard !isComposingAddress else { return .ignored }
                    moveSuggestionSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard !isComposingAddress else { return .ignored }
                    moveSuggestionSelection(by: -1)
                    return .handled
                }
                .onAppear {
                    addressFocused = true
                    DispatchQueue.main.async {
                        guard isEditing, addressFocused,
                              let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                        editor.selectAll(nil)
                    }
                }
        }
    }

    private var showsInitialSuggestions: Bool {
        addressText == prefilledAddress || addressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Local open pages make useful initial rows without disclosing the current URL to a
    /// suggestion provider. The currently displayed page is excluded instead of repeated.
    private var initialLocalSuggestions: [SearchManager.SearchSuggestion] {
        guard let spaceID = windowState.spaceID else { return [] }
        return browserManager.tabs.items(inSpace: spaceID)
            .filter { !$0.isFolder && $0.id != (splitItemID ?? windowState.selectedItemID) }
            .prefix(6).compactMap { item in
                let session = browserManager.tabs.session(for: item.id)
                guard let url = session?.url ?? item.url, url.absoluteString != prefilledAddress else { return nil }
                let title = item.customTitle ?? session?.title ?? item.displayTitle
                let match = SearchManager.TabMatch(itemID: item.id, title: title, url: url)
                return SearchManager.SearchSuggestion(text: title, type: .tab(match))
            }
    }

    private var expandedPanelWidth: CGFloat {
        min(440, max(240, (NSApp.keyWindow?.contentView?.bounds.width ?? 480) - 32))
    }

    private var expandedAddressPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                inlineAddressField
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            if !inlineSuggestions.isEmpty {
                Divider().padding(.horizontal, 10)
                inlineSuggestionList
            }
        }
        .background(colorScheme == .dark ? Color(white: 24.0 / 255.0) : .white,
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
            .strokeBorder(colorScheme == .dark ? Color(white: 75.0 / 255.0) : Color.black.opacity(0.2), lineWidth: 0.5))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.23), radius: 24, y: 10)
    }

    private var inlineSuggestionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(inlineSuggestions.enumerated()), id: \.offset) { index, suggestion in
                Button {
                    submitAddress(suggestion)
                } label: {
                    HStack(spacing: 12) {
                        AddressSuggestionFavicon(suggestion: suggestion, tabs: browserManager.tabs)
                            .frame(width: 20, height: 20)
                        if case .folder(let folder) = suggestion.type {
                            SuggestionLines(title: folder.title, detail: folder.path, detailLineLimit: nil)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            HStack(spacing: 6) {
                                Text(suggestionTitle(suggestion))
                                    .font(NookDesign.Font.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .layoutPriority(1)
                                if let host = suggestionURL(suggestion)?.host {
                                    Text("— " + host)
                                        .font(NookDesign.Font.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 45, alignment: .leading)
                    .background(index == selectedSuggestionIndex ? NookDesign.Surface.fillPressed : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding(6)
    }

    private func suggestionURL(_ suggestion: SearchManager.SearchSuggestion) -> URL? {
        switch suggestion.type {
        case .history(let entry): return entry.url
        case .tab(let match): return match.url
        case .url: return URL(string: normalizeURL(suggestion.text, queryTemplate: SearchProvider.google.queryTemplate))
        case .search, .folder, .action: return nil
        }
    }

    private func suggestionIcon(_ suggestion: SearchManager.SearchSuggestion) -> String {
        switch suggestion.type {
        case .history: return "clock"
        case .search: return "magnifyingglass"
        case .folder: return "folder"
        case .action: return "command"
        case .url, .tab: return "globe"
        }
    }

    private func suggestionTitle(_ suggestion: SearchManager.SearchSuggestion) -> String {
        if case .history(let entry) = suggestion.type { return entry.displayTitle }
        if case .tab(let match) = suggestion.type { return match.title }
        if case .folder(let folder) = suggestion.type { return folder.title }
        if case .action(let action) = suggestion.type { return action.title }
        return suggestion.text
    }

    private func beginEditing(_ address: String, target: AddressEditTarget? = nil) {
        if usesNativeEditor {
            guard nativeAddressIsAvailable,
                  let target = target ?? AddressEditTarget.capture(in: windowState, manager: browserManager),
                  target.address == address, target.isCurrent else { return }
            nativeEditTarget = target
            nativeEditPage = browserManager.frontPage(in: windowState)
        }
        searchManager.setTabs(browserManager.tabs, window: windowState)
        searchManager.setHistoryManager(browserManager.historyManager)
        if usesNativeEditor, let target = nativeEditTarget, let page = nativeEditPage {
            searchManager.setWebSuggestionTarget(for: page) { [weak window = windowState] in
                window?.isAddressEditing == true && target.isCurrent
            }
        } else { searchManager.clearWebSuggestionTarget() }
        prefilledAddress = address
        addressText = address
        selectedSuggestion = nil
        searchManager.clearSuggestions()
        isEditing = true
        windowState.isAddressEditing = true
        windowState.isSidebarResizeHovered = false
        hoverManager.setAddressEditing(true, in: windowState.id)
    }

    private func cancelEditing() {
        guard isEditing else { return }
        windowState.isAddressEditing = false
        hoverManager.setAddressEditing(false, in: windowState.id)
        isEditing = false
        nativeEditPage = nil; nativeEditTarget = nil
        addressFocused = false
        searchManager.clearWebSuggestionTarget()
    }

    private func submitAddress(_ chosen: SearchManager.SearchSuggestion? = nil) {
        // Capture before cancelEditing: retiring the editor may itself change
        // selection. Never retarget a stale address submission to its successor.
        let editPage = nativeEditPage, editTarget = nativeEditTarget
        let currentTarget = { !usesNativeEditor || editTarget?.isCurrent == true }
        guard !usesNativeEditor || isEditing, !isComposingAddress else { return }
        guard currentTarget() else { cancelEditing(); return }
        let suggestions = inlineSuggestions
        let selected = selectedSuggestion.flatMap { selection in suggestions.first { $0 == selection } }
        let typed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = typed.isEmpty ? nil : SearchManager.SearchSuggestion(text: typed, type: isLikelyURL(typed) ? .url : .search)
        guard let suggestion = chosen ?? selected ?? fallback else { return }
        if splitItemID == nil, case .tab(let match) = suggestion.type {
            guard browserManager.tabs.item(match.itemID) != nil else { return }
            cancelEditing()
            guard currentTarget() else { return }
            browserManager.tabs.select(match.itemID, in: windowState)
            return
        }
        let url: URL?
        switch suggestion.type {
        case .folder(let folder):
            cancelEditing()
            guard currentTarget() else { return }
            browserManager.tabs.reveal(folder.itemID, in: windowState)
            return
        case .action:
            return
        case .history(let entry): url = entry.url
        case .tab(let match): url = match.url
        case .url, .search:
            if usesNativeEditor,
               browserManager.openPasswordManagementCommand(
                suggestion.text, in: windowState, hasSearchOrPlacementOverride: suggestion.text != typed,
                dismissEditor: cancelEditing
               ) {
                return
            }
            if browserManager.tabs.profileEngine == .chromium, isSearchInput(suggestion.text) {
                cancelEditing()
                guard currentTarget() else { return }
                if usesNativeEditor, let page = editPage {
                    page.navigate(to: suggestion.text)
                } else {
                    browserManager.tabs.search(suggestion.text, in: windowState, splitItemID: splitItemID)
                }
                return
            }
            let template = browserManager.tabs.profileEngine == .chromium
                ? "nook-search:%@" : browserManager.tabs.searchTemplate(forSpace: windowState.spaceID)
            url = URL(string: normalizeURL(suggestion.text, queryTemplate: template))
        }
        guard let url else { return }
        cancelEditing()
        guard currentTarget() else { return }
        if let splitItemID {
            guard windowState.split?.contains(splitItemID) == true,
                  !browserManager.tabs.isPageShownElsewhere(splitItemID, from: windowState),
                  let session = browserManager.tabs.ensureSession(for: splitItemID) else { return }
            session.load(url)
            browserManager.tabs.select(splitItemID, in: windowState)
            return
        }
        if usesNativeEditor, let page = editPage {
            if browserManager.siteRoutingManager.applyRoute(navigating: page.url, to: url, page: page) { return }
            page.load(url)
            return
        }
        // Never navigate a live page owned by another window.
        let canReplace = browserManager.tabs.controllableSession(in: windowState) != nil
        browserManager.tabs.open(url: url, in: windowState,
                                 placement: canReplace ? .replaceCurrent : .newTab)
    }

    private var textColor: Color {
        .secondary
    }
    
    private func displayURL(for session: PageSession?) -> String {
        guard let session else { return "" }
        return formatURL(session.url)
    }

    private func isInsecure(for session: PageSession?) -> Bool { session?.url.scheme == "http" }
    /// The host, carrying the port when the URL names a non-default one. A development
    /// server at `localhost:3000` is a different origin from one at `localhost:8080`, so
    /// dropping the port left the bar showing the wrong thing. `URL.port` reports a port
    /// that was written out even when it is the scheme's default, so `https://x.com:443`
    /// still reads as `x.com`.
    private func displayHost(for session: PageSession?) -> String {
        guard let url = session?.url, let host = url.host else { return displayURL(for: session) }
        let defaultPort = url.scheme == "https" ? 443 : (url.scheme == "http" ? 80 : nil)
        guard let port = url.port, port != defaultPort else { return host }
        return "\(host):\(port)"
    }
    private func displayPath(for session: PageSession?) -> String {
        guard let url = session?.url else { return "" }
        return Self.shownPath(of: url, developerPage: isDevPage(session))
    }

    static func fieldFillOpacity(dark: Bool, hovering: Bool) -> Double {
        dark ? (hovering ? 0.14 : 0.10) : (hovering ? 0.05 : 0.08)
    }

    static func fieldFill(dark: Bool, hovering: Bool) -> Color {
        (dark ? Color.white : Color.black).opacity(fieldFillOpacity(dark: dark, hovering: hovering))
    }

    static func shownPath(of url: URL, developerPage: Bool) -> String {
        guard developerPage, url.host != nil else { return "" }
        guard let query = url.query else { return url.path == "/" ? "" : url.path }
        return url.path + "?" + query
    }

    private func isDevPage(_ session: PageSession?) -> Bool {
        guard let session, browserManager.nookSettings?.developerModeEnabled == true else { return false }
        return DevHosts.isDevHost(session.url)
    }

        private func formatURL(_ url: URL) -> String {
            guard let host = url.host else {
                return url.absoluteString
            }
            
            let cleanHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            
            return cleanHost
        }
    
    private func copyURLToClipboard(_ urlString: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
        
        // Show checkmark icon briefly
        withAnimation(NookDesign.Motion.standard) {
            showCheckmark = true
        }
        
        // Show toast notification
        windowState.isShowingCopyURLToast = true
        
        // Reset checkmark after 1 second
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(NookDesign.Motion.standard) {
                showCheckmark = false
            }
        }
        
        // Hide toast after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            windowState.isShowingCopyURLToast = false
        }
    }
}

/// SwiftUI reports the sidebar's whole frame as this element's once the element changed, or was made,
/// while the sidebar was faded out under the Library or out of the window. Made anew each time the
/// sidebar shows again, it reports its own frame.
private struct RenewedWhenSidebarShows: ViewModifier {
    @Environment(\.libraryProgress) private var progress
    @Environment(\.sidebarOutOfWindow) private var outOfWindow

    func body(content: Content) -> some View {
        content.id(progress > 0 || outOfWindow)
    }
}

/// Expose the collapsed address as an actionable element without combining or overriding
/// the native text field's accessibility tree while editing.
private struct AddressActivationAccessibility: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
        } else {
            content
        }
    }
}

private struct AddressSuggestionFavicon: View {
    let suggestion: SearchManager.SearchSuggestion
    let tabs: TabsController

    private var url: URL? {
        switch suggestion.type {
        case .history(let entry): return entry.url
        case .tab(let match): return match.url
        case .url: return URL(string: normalizeURL(suggestion.text, queryTemplate: SearchProvider.google.queryTemplate))
        case .search, .folder, .action: return nil
        }
    }

    var body: some View {
        Group {
            if case .tab(let match) = suggestion.type {
                match.favicon(in: tabs).resizable().scaledToFit()
            } else {
                Image(systemName: url == nil ? "magnifyingglass" : "globe")
                    .font(.system(size: 16)).foregroundStyle(.secondary)
            }
        }
    }
}

/// A scoped local monitor dismisses the overlay without swallowing the outside click.
/// Its view covers the panel, so field and suggestion clicks stay inside.
struct AddressOutsideClickRegion: NSViewRepresentable {
    let onOutsideClick: () -> Void

    final class Region: NSView {
        var onOutsideClick: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window else { return event }
                if event.window !== window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.onOutsideClick?()
                }
                return event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeNSView(context: Context) -> Region {
        let view = Region()
        view.onOutsideClick = onOutsideClick
        return view
    }
    func updateNSView(_ nsView: Region, context: Context) { nsView.onOutsideClick = onOutsideClick }
    static func dismantleNSView(_ nsView: Region, coordinator: ()) { nsView.stop() }
}

/// Mount above the web content in the same window: a pane's hosting view and mask would
/// otherwise clip the expanded editor. Its top edge stays aligned with the title.
/// Existing bounded sibling host shared by address editors and the palette
/// card. Content/state remains in its original SwiftUI owner; this owns only a
/// native mounting view. Closed panels have no host or active event observers.
struct AddressAnchoredPanel<Content: View>: NSViewRepresentable {
    let width: CGFloat
    var centered = false
    var isPresented = true
    var canPresent: (NSWindow) -> Bool = { _ in true }
    var onWindowBounds: ((CGRect) -> Void)?
    var onRetire: () -> Void = {}
    @ViewBuilder let content: () -> Content

    final class Hosting: NSHostingView<Content> {
        var onLayout: (() -> Void)?
        override func layout() { super.layout(); onLayout?() }
    }
    final class Anchor: NSView {
        var panelContent: Content?
        var panelWidth: CGFloat = 440
        var centered = false
        var isPresented = true
        var canPresent: (NSWindow) -> Bool = { _ in true }
        var onWindowBounds: ((CGRect) -> Void)?
        var onRetire: (() -> Void)?
        private var hostingView: Hosting?
        private var updating = false
        private var wasPresented = false
        private weak var observedWindow: NSWindow?
        private var resizeObserver: NSObjectProtocol?
        private var closeObserver: NSObjectProtocol?
        private var lastWindowBounds: CGRect?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { retirePanel() } else { updatePanel() }
        }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            if superview == nil { retirePanel() }
        }
        override func viewDidHide() { super.viewDidHide(); retirePanel() }
        override func viewDidUnhide() { super.viewDidUnhide(); updatePanel() }
        override func layout() { super.layout(); updatePanel() }

        private func observe(_ window: NSWindow) {
            guard observedWindow !== window else { return }
            stopObservers()
            observedWindow = window
            resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.updatePanel() } }
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.retirePanel() } }
        }
        private func stopObservers() {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            resizeObserver = nil; closeObserver = nil; observedWindow = nil
        }
        private func retirePanel() {
            let notify = wasPresented
            removePanel()
            if notify { onRetire?() }
        }
        func updatePanel() {
            guard !updating else { return }
            guard isPresented, !isHiddenOrHasHiddenAncestor, let window,
                  canPresent(window), let root = window.contentView,
                  let panelContent, bounds.width > 0 else { retirePanel(); return }
            if let host = hostingView, host.superview !== root { retirePanel(); return }
            updating = true
            defer { updating = false }
            observe(window)
            let rootBounds = root.bounds
            if rootBounds != lastWindowBounds {
                lastWindowBounds = rootBounds
                // Size publication only on an actual window change, never a
                // timer or unconditional content rebuild from layout.
                if onWindowBounds != nil {
                    DispatchQueue.main.async { [weak self, weak window] in
                        guard let self, let window, self.window === window,
                              self.isPresented, self.lastWindowBounds == rootBounds,
                              self.canPresent(window) else { return }
                        self.onWindowBounds?(rootBounds)
                    }
                }
            }
            let host: Hosting
            if let hostingView { host = hostingView }
            else {
                host = Hosting(rootView: panelContent)
                host.safeAreaRegions = []
                host.onLayout = { [weak self] in self?.updatePanel() }
                hostingView = host
            }
            let width = min(panelWidth, max(0, rootBounds.width - 16))
            let available = max(0, rootBounds.height - 16)
            let height = min(host.fittingSize.height, available)
            let anchorRect = root.convert(bounds, from: self)
            let x = centered ? rootBounds.midX - width / 2
                : min(max(rootBounds.minX + 8, anchorRect.minX), max(rootBounds.minX + 8, rootBounds.maxX - width - 8))
            let top = centered ? max(8, (rootBounds.height - min(560, available)) / 2)
                : (root.isFlipped ? anchorRect.minY - rootBounds.minY : rootBounds.maxY - anchorRect.maxY)
            let clampedTop = min(max(8, top), max(8, rootBounds.height - height - 8))
            let y = root.isFlipped ? rootBounds.minY + clampedTop : rootBounds.maxY - clampedTop - height
            let frame = NSRect(x: x, y: y, width: width, height: height)
            if host.frame != frame { host.frame = frame }
            if host.superview == nil {
                wasPresented = true
                root.addSubview(host, positioned: .above, relativeTo: nil)
            }
            guard self.window === window, window.contentView === root, isPresented,
                  canPresent(window) else { retirePanel(); return }
        }
        func setContent(_ content: Content) {
            panelContent = content
            hostingView?.rootView = content
            updatePanel()
        }
        func removePanel() {
            wasPresented = false
            stopObservers()
            hostingView?.onLayout = nil
            hostingView?.removeFromSuperview()
            hostingView = nil
        }
        deinit {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        }
    }
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ anchor: Anchor, context: Context) {
        anchor.panelWidth = width; anchor.centered = centered; anchor.isPresented = isPresented
        anchor.canPresent = canPresent; anchor.onWindowBounds = onWindowBounds; anchor.onRetire = onRetire
        anchor.setContent(content())
    }
    static func dismantleNSView(_ anchor: Anchor, coordinator: ()) {
        anchor.removePanel()
        anchor.panelContent = nil; anchor.onRetire = nil; anchor.onWindowBounds = nil
        anchor.canPresent = { _ in false }
    }
}

/// The expanded split editor lives in a separate hosting view, so give its native
/// field focus after attachment rather than sharing FocusState across hosting roots.
private struct SplitAddressSearchField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onMove: (Int) -> Void
    let onEndEditing: () -> Void

    final class Field: NSTextField {
        private var didRequestFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !didRequestFocus else { return }
            didRequestFocus = true
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isHiddenOrHasHiddenAncestor,
                      let window = self.window, window.isKeyWindow else { return }
                if window.makeFirstResponder(self) {
                    self.currentEditor()?.selectAll(nil)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SplitAddressSearchField
        init(_ parent: SplitAddressSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in self?.parent.onEndEditing() }
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            default: return false
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.placeholderString = "Search or Enter URL..."
        field.font = .systemFont(ofSize: 14)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.stringValue = text
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search or Enter URL...")
        return field
    }

    func updateNSView(_ nsView: Field, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text { nsView.stringValue = text }
    }
}
