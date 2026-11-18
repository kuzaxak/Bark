// Licensed under GPL-3.0. See LICENSE.
import Foundation

@main enum Check {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func setup(_ name: String) throws -> ChromiumOnboardingSetup {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return ChromiumOnboardingSetup(appDirectory: directory)
        }

        let fresh = try setup("fresh")
        let first = try fresh.requiresOnboarding(explicitlyFinished: false, hasSavedSetup: false)
        precondition(first)

        // Starter state may become valid on disk before onboarding is done.
        let relaunched = ChromiumOnboardingSetup(appDirectory: fresh.appDirectory)
        let interrupted = try relaunched.requiresOnboarding(explicitlyFinished: false, hasSavedSetup: true)
        precondition(interrupted)
        try relaunched.finish()
        let quitAfterFinish = try fresh.requiresOnboarding(explicitlyFinished: false, hasSavedSetup: false)
        precondition(!quitAfterFinish)

        let explicit = try setup("explicit")
        _ = try explicit.requiresOnboarding(explicitlyFinished: false, hasSavedSetup: false)
        let explicitlyFinished = try explicit.requiresOnboarding(explicitlyFinished: true, hasSavedSetup: false)
        precondition(!explicitlyFinished)
        let persistedExplicit = try explicit.requiresOnboarding(explicitlyFinished: false, hasSavedSetup: false)
        precondition(!persistedExplicit)

        let returning = try setup("saved")
        let preMarker = try returning.requiresOnboarding(explicitlyFinished: false, hasSavedSetup: true)
        precondition(!preMarker)
        let persistedReturning = try returning.requiresOnboarding(explicitlyFinished: false, hasSavedSetup: false)
        precondition(!persistedReturning)
        print("Onboarding: fresh, interrupted, completed and pre-marker setup PASS")
    }
}
