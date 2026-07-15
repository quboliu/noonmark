@testable import NoonmarkMacRuntime
import XCTest

final class AccessibilityPresentationPolicyTests: XCTestCase {
    func testDefaultPolicyKeepsMotionColorMarkersAndLayeredSurfaces() {
        let policy = makePolicy()

        XCTAssertTrue(policy.animatesTransitions)
        XCTAssertFalse(policy.usesTextualCountMarkers)
        XCTAssertEqual(policy.layeredSurfaceOpacity, 0.78)
        XCTAssertFalse(policy.usesEnhancedBoundaries)
    }

    func testEveryDisplayAccommodationChangesItsIndependentPresentationDecision() {
        let policy = makePolicy(
            increasesContrast: true,
            differentiatesWithoutColor: true,
            reducesMotion: true,
            reducesTransparency: true
        )

        XCTAssertFalse(policy.animatesTransitions)
        XCTAssertTrue(policy.usesTextualCountMarkers)
        XCTAssertEqual(policy.layeredSurfaceOpacity, 1)
        XCTAssertTrue(policy.usesEnhancedBoundaries)
    }

    private func makePolicy(
        increasesContrast: Bool = false,
        differentiatesWithoutColor: Bool = false,
        reducesMotion: Bool = false,
        reducesTransparency: Bool = false
    ) -> AccessibilityPresentationPolicy {
        AccessibilityPresentationPolicy(
            options: AccessibilityDisplayOptions(
                increasesContrast: increasesContrast,
                differentiatesWithoutColor: differentiatesWithoutColor,
                reducesMotion: reducesMotion,
                reducesTransparency: reducesTransparency
            )
        )
    }
}
