// Licensed under GPL-3.0. See LICENSE.
// swiftc Nook/Managers/SplitViewManager/AddSplit.swift Nook/Components/Browser/Window/SplitDrop.swift CommandPalette/CommandPalette.swift scripts/tests/AddSplitCheck.swift -o /tmp/addsplit && /tmp/addsplit

import Foundation

@main
struct AddSplitCheck {
    @MainActor static func main() async {
        let current = UUID(), other = UUID(), opened = UUID(), hiddenLeft = UUID(), hiddenRight = UUID(), third = UUID(), fourth = UUID()
        func layout(_ panes: [UUID], vertical: Bool = false) -> SplitDrop.Layout {
            SplitDrop.Layout(panes: panes, vertical: vertical, dividers: SplitDrop.equalDividers(panes.count), isFull: panes.count == 4)
        }
        let showing = layout([current, other])
        // A split saved from before, while the window shows another tab.
        let hidden = layout([hiddenLeft, hiddenRight])

        // A tab selected and no split: the tab stays on the left beside an empty pane.
        let adding = AddSplit.start(selectedItemID: current, split: nil)!
        precondition(adding.slots == [current, nil])
        precondition(adding.shows(selectedItemID: current, split: nil))
        precondition(AddSplit.start(selectedItemID: nil, split: nil) == nil, "no selection")
        // A saved split the window does not show is no split: the selected tab gets a new one.
        precondition(AddSplit.start(selectedItemID: current, split: hidden) == adding, "a hidden split")
        precondition(adding.shows(selectedItemID: current, split: hidden))

        // With a split showing, the empty pane goes after its last pane, or below the bottom one.
        let more = AddSplit.start(selectedItemID: current, split: showing)!
        precondition(more.slots == [current, other, nil] && !more.vertical)
        let below = AddSplit.start(selectedItemID: other, split: layout([current, other], vertical: true))!
        precondition(below.slots == [current, other, nil] && below.vertical)
        // A pane's Add Left Split puts the empty pane before it, Add Right Split after it.
        precondition(AddSplit.start(beside: other, after: false, selectedItemID: current, split: showing)?.slots == [current, nil, other])
        precondition(AddSplit.start(beside: current, after: true, selectedItemID: current, split: showing)?.slots == [current, nil, other])
        precondition(AddSplit.start(beside: third, after: true, selectedItemID: current, split: showing) == nil, "not a pane")

        // Every entry (the command bar, ⌃⇧=, the sidebar's New Split) is on offer until four panes
        // show; with no tab selected it is offered and does nothing.
        let full = layout([current, other, third, fourth])
        precondition(AddSplit.isOffered(selectedItemID: current, split: nil))
        precondition(AddSplit.isOffered(selectedItemID: current, split: hidden), "a hidden split")
        precondition(AddSplit.isOffered(selectedItemID: current, split: showing), "room for a third pane")
        precondition(!AddSplit.isOffered(selectedItemID: current, split: full), "four panes")
        precondition(AddSplit.start(selectedItemID: current, split: full) == nil)
        precondition(AddSplit.start(beside: current, after: true, selectedItemID: current, split: full) == nil)
        precondition(AddSplit.isOffered(selectedItemID: nil, split: nil) && AddSplit.start(selectedItemID: nil, split: nil) == nil)

        // An open tab moves into the empty pane; an address or a search fills it with the tab it opened.
        precondition(adding.filling(choosing: other, selectedItemID: current, split: nil) == other, "tab")
        precondition(adding.filling(choosing: opened, selectedItemID: current, split: nil) == opened, "URL")
        precondition(adding.filling(choosing: hiddenRight, selectedItemID: current, split: hidden) == hiddenRight)
        precondition(more.filling(choosing: opened, selectedItemID: other, split: showing) == opened, "any pane may be selected")
        // A tab already showing cannot fill the empty pane too: the window stays as it was.
        precondition(adding.filling(choosing: current, selectedItemID: current, split: nil) == nil, "left tab")
        precondition(more.filling(choosing: other, selectedItemID: current, split: showing) == nil, "a pane's tab")

        // Another tab or space selected, a pane's tab closed, or the split changed some other way:
        // the empty pane goes, and a late choice changes nothing.
        precondition(!adding.shows(selectedItemID: other, split: nil))
        precondition(!adding.shows(selectedItemID: nil, split: nil))
        precondition(!adding.shows(selectedItemID: current, split: showing), "a split made some other way")
        precondition(!more.shows(selectedItemID: current, split: nil), "the split ended")
        precondition(!more.shows(selectedItemID: current, split: layout([current, other, third])), "a pane added")
        precondition(adding.filling(choosing: opened, selectedItemID: other, split: nil) == nil)

        // While the empty pane shows, a tab dropped on it fills it, and the rest of the page,
        // laid out with the empty pane, takes no drop.
        let page = CGRect(x: 0, y: 0, width: 800, height: 600)
        func dragged(_ id: UUID, isTab: Bool = true) -> SplitDrop.Dragged { SplitDrop.Dragged(id: id, isTab: isTab, isInWindow: true) }
        precondition(adding.dropZone(for: dragged(opened), at: CGPoint(x: 700, y: 300), in: page, gap: 8)
                     == CGRect(x: 404, y: 0, width: 396, height: 600), "the empty pane")
        precondition(adding.dropZone(for: dragged(opened), at: CGPoint(x: 100, y: 300), in: page, gap: 8) == nil, "the tab's pane")
        precondition(adding.dropZone(for: dragged(current), at: CGPoint(x: 700, y: 300), in: page, gap: 8) == nil, "a tab the window shows")
        precondition(adding.dropZone(for: dragged(opened, isTab: false), at: CGPoint(x: 700, y: 300), in: page, gap: 8) == nil, "a folder")
        let between = AddSplit.start(beside: other, after: false, selectedItemID: current, split: showing)!
        precondition(between.dropZone(for: dragged(opened), at: CGPoint(x: 400, y: 300), in: page, gap: 8)?.minX == 270,
                     "an empty pane between two panes")
        precondition(between.dropZone(for: dragged(opened), at: CGPoint(x: 700, y: 300), in: page, gap: 8) == nil)

        // The bar lists the window's own space's tabs and pages to open: another space's tab
        // would switch spaces, and folders and actions fill no pane.
        let space = UUID(), elsewhere = UUID()
        precondition(AddSplit.offers(.tab(spaceID: space), windowSpace: space))
        precondition(!AddSplit.offers(.tab(spaceID: elsewhere), windowSpace: space), "another space's tab")
        precondition(AddSplit.offers(.page, windowSpace: space), "an address, a search or a history entry")
        precondition(!AddSplit.offers(.other, windowSpace: space), "a folder or an action")

        // The bar holds the empty pane while it is open for it. Escape, a click outside and the
        // pane's close button all close the bar, which drops it; opening the bar for anything
        // else (Cmd+T, Cmd+L) drops it too.
        let palette = CommandPalette()
        palette.open(addSplit: adding)
        precondition(palette.addSplit == adding && palette.addressEdit == nil)
        palette.close()
        precondition(palette.addSplit == nil, "cancel")
        palette.open(addSplit: adding)
        palette.open(prefill: "> Move to Space")
        precondition(palette.addSplit == nil && palette.addressEdit == nil && palette.prefilledText == "> Move to Space",
                     "Prefilling an action replaces Add Split without creating an address edit")
        palette.close()
        await checkAddressEdit()
        print("AddSplitCheck passed")
    }

    @MainActor private static func checkAddressEdit() async {
        let palette = CommandPalette()
        let window = NSObject(), otherWindow = NSObject()
        let tab = NSObject(), otherTab = NSObject(), peek = NSObject()
        let navigation = NSObject(), replacement = NSObject()
        let sameURL = URL(string: "https://example.com")!
        let space = UUID(), otherSpace = UUID(), item = UUID(), profile = UUID()
        func owner(window: NSObject, space: UUID = space, selection: UUID? = item,
                   page: NSObject? = tab, navigation: NSObject? = navigation, url: URL? = sameURL,
                   nativeWindow: Int32? = 1, nativeTab: Int32? = 2, document: UInt64? = 4) -> AddressEditTarget.Context {
            .init(window: ObjectIdentifier(window), space: space, selection: selection,
                  page: page.map(ObjectIdentifier.init), navigation: navigation.map(ObjectIdentifier.init),
                  nativeWindow: nativeWindow, nativeTab: nativeTab, document: document, profile: profile, address: url)
        }
        var front: AddressEditTarget.Context? = owner(window: window)
        let edit = AddressEditTarget { front }!
        precondition(edit.isCurrent && edit.address == sameURL.absoluteString)
        for changed in [
            owner(window: otherWindow),
            owner(window: window, space: otherSpace),
            owner(window: window, page: otherTab),
            owner(window: window, page: peek),
            owner(window: window, navigation: replacement),
            owner(window: window, nativeWindow: 3),
            owner(window: window, document: 5),
            owner(window: window, url: URL(string: "https://example.com/redirect")),
            nil
        ] {
            front = changed
            precondition(!edit.isCurrent, "A changed owner cannot receive the earlier address edit")
        }

        front = owner(window: window)
        palette.openAddressEdit(edit)
        precondition(palette.addressEdit?.id == edit.id && palette.prefilledText == sameURL.absoluteString)
        front = owner(window: window, page: otherTab)
        await finishPresentation()
        precondition(!palette.isVisible && palette.addressEdit == nil,
                     "A queued edit cannot present on another same-URL page")

        front = owner(window: window, page: nil, navigation: nil, url: nil)
        precondition(AddressEditTarget { front } == nil, "An unavailable selected page is not empty")
        front = owner(window: window, selection: nil, page: nil, navigation: nil, url: nil)
        let empty = AddressEditTarget { front }!
        palette.openAddressEdit(empty)
        await finishPresentation()
        precondition(palette.isVisible && empty.isCurrent && palette.prefilledText.isEmpty,
                     "A genuinely empty space can accept an address")
        front = owner(window: window)
        precondition(!empty.isCurrent, "A page that arrives during an empty edit cannot receive it")

        palette.close()
        palette.open()
        await finishPresentation()
        precondition(palette.isVisible && palette.addressEdit == nil,
                     "A new-tab invocation is independent of the prior edit")
        palette.close()
        palette.open()
        palette.close()
        await finishPresentation()
        precondition(!palette.isVisible, "A dismissed palette cannot reopen from its queued presentation")
    }

    @MainActor private static func finishPresentation() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

}
