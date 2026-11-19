// Licensed under GPL-3.0. See LICENSE.
import Foundation

enum NativePageLoadingSweep {
    /// Where the sweep is `time` seconds in: it enters from the left and leaves on the right.
    static func frame(at time: TimeInterval, width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let period = 1.2
        let phase = CGFloat(time.truncatingRemainder(dividingBy: period) / period)
        let length = width * 0.3
        return (x: -length + (width + length) * phase, width: length)
    }
}
