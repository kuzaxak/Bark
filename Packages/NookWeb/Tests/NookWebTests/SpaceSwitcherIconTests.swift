// Licensed under GPL-3.0. See LICENSE.
import Testing
@testable import NookWeb

/// The space bar shows which space is current as Arc's does: its icon at full strength, every
/// other one faded and grey, a hovered one part way back, and a swipe cross-fading the two.
struct SpaceSwitcherIconTests {
    @Test func theCurrentSpaceShowsAtFullStrength() {
        let look = SpaceSwitcher.iconLook(selection: 1, hovered: false)
        #expect(look.opacity == 1)
        #expect(look.saturation == 1)
        #expect(SpaceSwitcher.iconLook(selection: 1, hovered: true) == look, "hover changes nothing on the current space")
    }

    @Test func otherSpacesAreFadedAndGrey() {
        let look = SpaceSwitcher.iconLook(selection: 0, hovered: false)
        #expect(look.opacity > 0 && look.opacity < 1)
        #expect(look.saturation == 0)
    }

    @Test func hoverBringsAnotherSpaceUpPartWay() {
        let dimmed = SpaceSwitcher.iconLook(selection: 0, hovered: false)
        let hovered = SpaceSwitcher.iconLook(selection: 0, hovered: true)
        #expect(hovered.opacity > dimmed.opacity && hovered.opacity < 1)
        #expect(hovered.saturation > 0 && hovered.saturation < 1)
    }

    @Test func aSwipeCrossFadesWithItsProgress() {
        let steps = [0, 0.25, 0.5, 0.75, 1].map { SpaceSwitcher.iconLook(selection: $0, hovered: false) }
        for (before, after) in zip(steps, steps.dropFirst()) {
            #expect(after.opacity > before.opacity)
            #expect(after.saturation > before.saturation)
        }
    }
}
