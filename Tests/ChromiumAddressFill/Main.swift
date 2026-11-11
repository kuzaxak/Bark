// Licensed under GPL-3.0. See LICENSE.
// check.py compiles the shipped fill rule verbatim. Arc's capture: white about 0.10 over the sidebar at
// rest and 0.14 under the pointer, so the field lightens on hover.
import Foundation

@main enum Check {
    static func main() {
        let darkRest = URLBarView.fieldFillOpacity(dark: true, hovering: false), darkHover = URLBarView.fieldFillOpacity(dark: true, hovering: true)
        let lightRest = URLBarView.fieldFillOpacity(dark: false, hovering: false), lightHover = URLBarView.fieldFillOpacity(dark: false, hovering: true)
        precondition(abs(darkRest - 0.10) < 0.005 && abs(darkHover - 0.14) < 0.005, "over a dark sidebar the field is Arc's: \(darkRest) at rest, \(darkHover) on hover")
        precondition(lightHover < lightRest, "over a light sidebar the pointer lightens the field too: \(lightRest) at rest, \(lightHover) on hover")
        precondition(lightRest == 0.08, "its rest fill stays")
        print("Address fill: the pointer lightens the field over dark and light sidebars, as in Arc")
    }
}
