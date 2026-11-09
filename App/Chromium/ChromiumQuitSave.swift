import Foundation
import OSLog

/// What an accepted quit saves, in the order of `AppDelegate.applicationShouldTerminate`.
@MainActor
final class ChromiumQuitSave {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "QuitSave")
    private let flushTabs: () -> Void
    private let flushBoosts: () -> Void
    private let saveContext: () throws -> Void
    private let report: (Error) -> Void
    private var saved = false

    init(flushTabs: @escaping () -> Void, flushBoosts: @escaping () -> Void, saveContext: @escaping () throws -> Void,
         report: @escaping (Error) -> Void = { error in
             ChromiumQuitSave.log.error("Context save at quit failed: \(String(describing: error), privacy: .public)")
         }) {
        self.flushTabs = flushTabs
        self.flushBoosts = flushBoosts
        self.saveContext = saveContext
        self.report = report
    }

    func save() {
        guard !saved else { return }
        saved = true
        flushTabs()
        flushBoosts()
        do {
            try saveContext()
        } catch {
            report(error)
        }
    }

    func cancelled() { saved = false }
}
