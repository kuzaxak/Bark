@testable import NookNativeShell
import AppKit
import BarcChromium

@MainActor
private enum Native {
    static var flags: UInt32 = BARC_EXTENSION_ENABLED.rawValue
    static var available = true
    static var accepts = true
    static var onList: (() -> Void)?
    static var calls: [String] = []
    static var hostCallback: BarcWindowHostCallback?
    static var hostContext: UnsafeMutableRawPointer?

    static var bridge: BarcBridge {
        var bridge = trappingBridge
        bridge.tab_list_extension_actions = { client, tab, callback, context in
            MainActor.assumeIsolated {
                Native.calls.append("list:\(client):\(tab)")
                let next = Native.onList
                Native.onList = nil
                next?()
                guard Native.available, let callback else { return 0 }
                func emit(_ id: String, _ title: String, _ badge: String, _ flags: UInt32) {
                    id.withCString { id in title.withCString { title in badge.withCString { badge in
                        callback(context, id, title, badge, Int32(bitPattern: flags))
                    } } }
                }
                emit("fixture", "Bark fixture action", "12", Native.flags)
                emit("locked", "Locked action", "", BARC_EXTENSION_PINNED.rawValue | BARC_EXTENSION_PIN_LOCKED.rawValue)
                return 1
            }
        }
        bridge.tab_set_extension_pinned = { client, tab, id, pinned in
            MainActor.assumeIsolated {
                Native.calls.append("pin:\(client):\(tab):\(String(cString: id!)):\(pinned)")
                return Native.accepts ? 1 : 0
            }
        }
        bridge.tab_invoke_extension = { client, tab, id in
            MainActor.assumeIsolated {
                Native.calls.append("invoke:\(client):\(tab):\(String(cString: id!))")
                return Native.accepts ? 1 : 0
            }
        }
        bridge.window_host_observe = { client, callback, context in
            MainActor.assumeIsolated {
                precondition(client == 10)
                Native.hostCallback = callback
                Native.hostContext = context
                return 77
            }
        }
        bridge.window_set_root_view = { _, _ in 1 }
        bridge.window_host_unobserve = { token in
            MainActor.assumeIsolated {
                precondition(token == 77)
                Native.hostCallback = nil
                Native.hostContext = nil
            }
        }
        return bridge
    }
}

@main
private enum ExtensionActionChecks {
    @MainActor static func main() {
        let actions = ChromiumExtensionActions()
        var mountedClient: Int32 = 10
        var mountedTab: Int32 = 11
        var key = true
        func target(_ client: Int32, _ tab: Int32) -> ChromiumExtensionActionTarget {
            .init(bridge: Native.bridge, client: client, tab: tab,
                  isCurrent: { mountedClient == client && mountedTab == tab },
                  canPerform: { key })
        }

        actions.refresh(target(10, 11))
        let initial = actions.snapshot!
        let fixture = initial.rows[0], locked = initial.rows[1]
        precondition(fixture.title == "Bark fixture action" && fixture.badge == "12" && fixture.enabled)
        precondition(fixture.pinLabel == "Pin Bark fixture action")
        precondition(locked.pinned && locked.pinLocked && !locked.enabled && locked.pinLabel == "Locked action is pinned by policy")
        actions.togglePin(locked, in: initial)
        precondition(!actions.invoke(locked, in: initial))
        precondition(Native.calls == ["list:10:11"])

        actions.togglePin(fixture, in: initial)
        precondition(Native.calls.suffix(2) == ["pin:10:11:fixture:1", "list:10:11"])
        precondition(actions.snapshot?.rows[0].pinned == false, "the displayed pin comes from Chromium's refreshed list")

        Native.flags |= BARC_EXTENSION_PINNED.rawValue
        actions.refresh(target(10, 11))
        let pinned = actions.snapshot!
        precondition(pinned.rows[0].pinLabel == "Unpin Bark fixture action")
        precondition(actions.invoke(pinned.rows[0], in: pinned))
        precondition(Native.calls.last == "invoke:10:11:fixture")

        mountedTab = 12
        let beforeStale = Native.calls
        precondition(!actions.invoke(pinned.rows[0], in: pinned))
        precondition(actions.snapshot == nil && Native.calls == beforeStale)

        // A queued old button cannot clear or dispatch through the new window's list.
        mountedClient = 20; mountedTab = 21
        actions.refresh(target(20, 21))
        let successor = actions.snapshot!
        actions.togglePin(pinned.rows[0], in: pinned)
        precondition(actions.snapshot === successor && Native.calls.last == "list:20:21")

        key = false
        precondition(!actions.invoke(successor.rows[0], in: successor) && actions.snapshot == nil)
        precondition(Native.calls.last == "list:20:21")
        key = true

        // A reentrant list result for the previous space cannot replace the newcomer.
        Native.onList = {
            mountedClient = 30; mountedTab = 31
            actions.refresh(target(30, 31))
        }
        actions.refresh(target(20, 21))
        precondition(actions.snapshot?.target.client == 30 && actions.snapshot?.target.tab == 31)

        let changed = actions.snapshot!
        Native.accepts = false
        precondition(!actions.invoke(changed.rows[0], in: changed) && actions.snapshot == nil)
        Native.available = false
        actions.refresh(target(30, 31))
        precondition(actions.snapshot == nil)

        var changes = 0
        let root = NSView()
        let link = ChromiumWindowHostLink(bridge: Native.bridge) { change in
            if case .extensionActionsChanged = change { changes += 1 }
        }
        precondition(link.attach(root, client: 10))
        var event = BarcWindowHostEvent()
        event.size = MemoryLayout<BarcWindowHostEvent>.size
        event.kind = Int32(bitPattern: BARC_WINDOW_HOST_EXTENSION_ACTIONS_CHANGED.rawValue)
        withUnsafePointer(to: &event) { Native.hostCallback?($0, Native.hostContext) }
        precondition(changes == 1)
        print("Chromium extension actions preserve the displayed owner, native pin state and host invalidation")
    }
}
