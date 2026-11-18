import BarcChromium
import NookDesign
import NookUI
import SwiftUI

struct ChromiumExtensionAction: Identifiable, Equatable {
    let id: String
    let title: String
    let badge: String
    let flags: UInt32

    var pinned: Bool { flags & BARC_EXTENSION_PINNED.rawValue != 0 }
    var enabled: Bool { flags & BARC_EXTENSION_ENABLED.rawValue != 0 }
    var pinLocked: Bool { flags & BARC_EXTENSION_PIN_LOCKED.rawValue != 0 }
    var pinLabel: String {
        if pinLocked { return "\(title) is pinned by policy" }
        return pinned ? "Unpin \(title)" : "Pin \(title)"
    }
}

/// The native handles and current mounted page that supplied a snapshot.
@MainActor
struct ChromiumExtensionActionTarget {
    let bridge: BarcBridge
    let client: Int32
    let tab: Int32
    let isCurrent: () -> Bool
    let canPerform: () -> Bool
}

@MainActor
@Observable
final class ChromiumExtensionActions {
    final class Snapshot {
        let target: ChromiumExtensionActionTarget
        let rows: [ChromiumExtensionAction]

        fileprivate init(target: ChromiumExtensionActionTarget, rows: [ChromiumExtensionAction]) {
            self.target = target
            self.rows = rows
        }
    }

    private final class BorrowedList {
        var rows: [ChromiumExtensionAction] = []
        var ids = Set<String>()
    }

    private(set) var snapshot: Snapshot?
    @ObservationIgnored private var generation: UInt64 = 0

    func refresh(_ target: ChromiumExtensionActionTarget?) {
        generation &+= 1
        let current = generation
        guard let target, target.isCurrent() else {
            if generation == current { snapshot = nil }
            return
        }
        let list = BorrowedList()
        let result = withExtendedLifetime(list) {
            target.bridge.tab_list_extension_actions(target.client, target.tab, { context, id, title, badge, flags in
                MainActor.assumeIsolated {
                    guard let context, let id, let title, let badge,
                          let identifier = String(validatingCString: id), !identifier.isEmpty,
                          let name = String(validatingCString: title), let badgeText = String(validatingCString: badge)
                    else { return }
                    let list = Unmanaged<BorrowedList>.fromOpaque(context).takeUnretainedValue()
                    guard list.ids.insert(identifier).inserted else { return }
                    list.rows.append(.init(id: identifier, title: name.isEmpty ? identifier : name,
                                           badge: badgeText, flags: UInt32(bitPattern: flags)))
                }
            }, Unmanaged.passUnretained(list).toOpaque())
        }
        // A reentrant selection can publish a newer list while the bridge is on the stack.
        let ready = result == 1 && target.isCurrent()
        guard generation == current else { return }
        snapshot = ready ? Snapshot(target: target, rows: list.rows) : nil
    }

    func togglePin(_ row: ChromiumExtensionAction, in displayed: Snapshot) {
        guard !row.pinLocked, authorize(row, in: displayed) else { return }
        let target = displayed.target
        let accepted = row.id.withCString { target.bridge.tab_set_extension_pinned(target.client, target.tab, $0, row.pinned ? 0 : 1) }
        if snapshot === displayed { refresh(accepted == 1 ? target : nil) }
    }

    @discardableResult
    func invoke(_ row: ChromiumExtensionAction, in displayed: Snapshot) -> Bool {
        guard row.enabled, authorize(row, in: displayed) else { return false }
        let target = displayed.target
        let accepted = row.id.withCString { target.bridge.tab_invoke_extension(target.client, target.tab, $0) } == 1
        if !accepted && snapshot === displayed { refresh(nil) }
        return accepted
    }

    private func authorize(_ row: ChromiumExtensionAction, in displayed: Snapshot) -> Bool {
        guard snapshot === displayed, displayed.rows.contains(row) else { return false }
        guard displayed.target.isCurrent(), displayed.target.canPerform() else {
            if snapshot === displayed { refresh(nil) }
            return false
        }
        return snapshot === displayed
    }
}

extension EnvironmentValues {
    @Entry var chromiumExtensionActions: ChromiumExtensionActions? = nil
}

struct ChromiumExtensionActionList: View {
    let actions: ChromiumExtensionActions
    let dismiss: () -> Void
    private let rowHeight: CGFloat = 26

    var body: some View {
        if let displayed = actions.snapshot, !displayed.rows.isEmpty {
            VStack(alignment: .leading, spacing: NookDesign.Spacing.sm) {
                Text("Extensions").font(NookDesign.Font.label)
                ScrollView {
                    VStack(spacing: NookDesign.Spacing.xs) {
                        ForEach(displayed.rows) { row in
                            HStack(spacing: NookDesign.Spacing.xs) {
                                Button {
                                    if actions.invoke(row, in: displayed) { dismiss() }
                                } label: {
                                    HStack {
                                        Image(systemName: "puzzlepiece.extension")
                                        Text(row.title).lineLimit(1)
                                        Spacer(minLength: 0)
                                        if !row.badge.isEmpty {
                                            Text(row.badge).font(.caption2).monospacedDigit().lineLimit(1)
                                        }
                                    }.contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!row.enabled)
                                .accessibilityLabel(row.title)
                                .accessibilityValue(row.badge)
                                .chromiumSiteControlsPointerTarget(enabled: row.enabled)

                                Button(row.pinLabel, systemImage: row.pinned ? "pin.fill" : "pin") {
                                    actions.togglePin(row, in: displayed)
                                }
                                .labelStyle(.iconOnly)
                                .disabled(row.pinLocked)
                                .help(row.pinLabel)
                                .chromiumSiteControlsPointerTarget(enabled: !row.pinLocked)
                            }
                            .frame(height: rowHeight)
                        }
                    }
                }
                .frame(height: min(190, CGFloat(displayed.rows.count) * rowHeight +
                    CGFloat(displayed.rows.count - 1) * NookDesign.Spacing.xs))
            }
        }
    }
}

struct ChromiumPinnedExtensionActions: View {
    let actions: ChromiumExtensionActions

    var body: some View {
        if let displayed = actions.snapshot {
            ForEach(displayed.rows.filter(\.pinned)) { row in
                Button(row.title, systemImage: "puzzlepiece.extension") {
                    actions.invoke(row, in: displayed)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(NookIconButtonStyle(size: NookDesign.Size.addressButton, radius: NookDesign.Radius.sm))
                .accessibilityValue(row.badge)
                .help(row.title)
                .disabled(!row.enabled)
                .overlay(alignment: .topTrailing) {
                    if !row.badge.isEmpty {
                        Text(row.badge).font(.system(size: 8, weight: .semibold))
                            .lineLimit(1).padding(.horizontal, 2)
                            .foregroundStyle(.white).background(.tint, in: Capsule())
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            }
        }
    }
}
