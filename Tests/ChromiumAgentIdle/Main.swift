// Licensed under GPL-3.0. See LICENSE.
// check.py compiles the shipped AgentIdleClose with a short delay in place of half an hour.
import Foundation

@main @MainActor enum Check {
    static func main() async {
        var calls = 0, closes = 0
        let idle = AgentIdleClose(delay: .milliseconds(200), calls: { calls }, close: { closes += 1 })
        try? await Task.sleep(for: .milliseconds(300))
        precondition(closes == 0, "an agent that never ran closes nothing")

        calls = 1; idle.callsChanged()
        try? await Task.sleep(for: .milliseconds(300))
        precondition(closes == 0, "nothing closes while a tool call runs")
        calls = 0; idle.callsChanged()
        try? await Task.sleep(for: .milliseconds(60))
        precondition(closes == 0, "nor before the delay")
        try? await Task.sleep(for: .milliseconds(300))
        precondition(closes == 1, "the Agent space's tabs close once no call has run for the delay")

        calls = 1; idle.callsChanged(); calls = 0; idle.callsChanged()
        try? await Task.sleep(for: .milliseconds(120))
        calls = 1; idle.callsChanged()
        try? await Task.sleep(for: .milliseconds(300))
        precondition(closes == 1, "a new call puts it off")
        calls = 0; idle.callsChanged()
        try? await Task.sleep(for: .milliseconds(120))
        idle.callsChanged()
        try? await Task.sleep(for: .milliseconds(120))
        precondition(closes == 1, "the delay counts from the last call")
        try? await Task.sleep(for: .milliseconds(200))
        precondition(closes == 2, "then they close again")
        calls = 0; idle.callsChanged()
        try? await Task.sleep(for: .milliseconds(150))
        calls = 1
        try? await Task.sleep(for: .milliseconds(150))
        precondition(closes == 2, "a call that started before its notice arrives still keeps the tabs")
        print("Agent idle: the Agent space's tabs close once no tool call has run for the delay")
    }
}
