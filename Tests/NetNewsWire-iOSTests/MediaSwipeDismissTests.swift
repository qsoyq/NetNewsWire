import Testing
import UIKit
@testable import NetNewsWire

@Suite struct MediaSwipeDismissTests {

	private let height: CGFloat = 800

	@Test(arguments: [CGFloat(-1), 1])
	func fastFlickDismissesInEitherDirection(direction: CGFloat) {
		#expect(MediaSwipeDismiss.shouldDismiss(translation: 10 * direction, velocity: 900 * direction, height: height))
	}

	@Test(arguments: [CGFloat(-1), 1])
	func farSlowDragDismissesInEitherDirection(direction: CGFloat) {
		#expect(MediaSwipeDismiss.shouldDismiss(translation: 150 * direction, velocity: 0, height: height))
	}

	@Test(arguments: [CGFloat(-1), 1])
	func shortSlowDragSnapsBack(direction: CGFloat) {
		#expect(!MediaSwipeDismiss.shouldDismiss(translation: 40 * direction, velocity: 100 * direction, height: height))
	}

	@Test func fastFlickBackTowardRestCancels() {
		#expect(!MediaSwipeDismiss.shouldDismiss(translation: 60, velocity: -900, height: height))
	}

	@Test func controlsFadeWithDistance() {
		#expect(MediaSwipeDismiss.controlsAlpha(distance: 0) == 1)
		#expect(MediaSwipeDismiss.controlsAlpha(distance: 40) == 0.5)
		#expect(MediaSwipeDismiss.controlsAlpha(distance: -400) == 0)
	}
}
