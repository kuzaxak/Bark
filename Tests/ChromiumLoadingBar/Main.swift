// Licensed under GPL-3.0. See LICENSE.
// Compiles the shipped sweep: an indeterminate bar that keeps crossing and never reads as a percent.
import Foundation

@main struct Main {
    static func main() {
        let width: CGFloat = 200
        let start = NativePageLoadingSweep.frame(at: 0, width: width)
        precondition(start.x + start.width == 0, "it enters from just off the left")
        var last = start.x
        for step in 1..<12 {
            let now = NativePageLoadingSweep.frame(at: Double(step) * 0.1, width: width)
            precondition(now.x > last, "it keeps moving right")
            precondition(now.width == start.width, "its length says nothing about progress")
            last = now.x
        }
        precondition(last < width && last > width * 0.8, "it reaches the right edge")
        let again = NativePageLoadingSweep.frame(at: 1.2 + 1e-9, width: width)
        precondition(abs(again.x - start.x) < 1, "then starts over")
        let narrow = NativePageLoadingSweep.frame(at: 0.6, width: width / 2)
        let wide = NativePageLoadingSweep.frame(at: 0.6, width: width)
        precondition(narrow.x * 2 == wide.x && narrow.width * 2 == wide.width,
                     "the same sweep scales across window sizes")
        let empty = NativePageLoadingSweep.frame(at: 0.6, width: 0)
        precondition(empty.x == 0 && empty.width == 0)
        print("Loading bar: the sweep crosses and repeats with a fixed length")
    }
}
