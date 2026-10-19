//
//  MediaSwipeDismiss.swift
//  NetNewsWire-iOS
//
//  Shared rules for swiping full-screen media (images and videos) away.
//

import UIKit

enum MediaSwipeDismiss {

	/// A flick faster than this dismisses regardless of distance (points per second).
	static let velocityThreshold: CGFloat = 700

	/// Distance (as a fraction of the view height) that dismisses a slow drag.
	static let distanceFraction: CGFloat = 1.0 / 8.0

	/// Drag distance over which the surrounding controls fade out.
	static let controlsFadeDistance: CGFloat = 80

	/// - Parameters:
	///   - translation: Signed drag distance from the resting position.
	///   - velocity: Signed velocity in points per second, same sign convention as `translation`.
	///   - height: Height of the dismissed view.
	static func shouldDismiss(translation: CGFloat, velocity: CGFloat, height: CGFloat) -> Bool {
		if abs(velocity) > velocityThreshold {
			// A fast flick back toward the resting position cancels the dismissal.
			return translation * velocity >= 0
		}
		return abs(translation) > height * distanceFraction
	}

	static func controlsAlpha(distance: CGFloat) -> CGFloat {
		1 - min(1, max(0, abs(distance) / controlsFadeDistance))
	}
}

/// Lets the user swipe the native video player up or down to close it.
///
/// `AVPlayerViewController` presented modally has no swipe-to-dismiss of its own. A vertical
/// pan recognizer is added next to the player's own recognizers (never replacing them), the
/// view follows the finger, and releasing past the threshold slides it off screen.
@MainActor
final class VideoSwipeDismissGesture: NSObject, UIGestureRecognizerDelegate {

	/// Touches this close to the bottom edge belong to the playback controls and scrubber.
	private static let controlsExclusionHeight: CGFloat = 110

	private let onDismiss: () -> Void
	private weak var targetView: UIView?
	private var isDismissing = false

	init(onDismiss: @escaping () -> Void) {
		self.onDismiss = onDismiss
		super.init()
	}

	func install(on controller: UIViewController) {
		let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
		pan.delegate = self
		pan.cancelsTouchesInView = false
		controller.view.addGestureRecognizer(pan)
		targetView = controller.view
	}

	func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
		guard !isDismissing, let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view else {
			return false
		}
		let velocity = pan.velocity(in: view)
		guard abs(velocity.y) > abs(velocity.x) else {
			return false
		}
		// The recognizer begins after the finger has moved, so use where the touch started.
		// Drags that start on the bottom controls or scrubber must keep belonging to them.
		let current = pan.location(in: view)
		let translation = pan.translation(in: view)
		let startY = current.y - translation.y
		let exclusion = max(Self.controlsExclusionHeight, view.safeAreaInsets.bottom + 80)
		return startY < view.bounds.height - exclusion
	}

	func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
		true
	}

	@objc private func handlePan(_ pan: UIPanGestureRecognizer) {
		guard let view = pan.view, !isDismissing else {
			return
		}
		let translation = pan.translation(in: view).y
		switch pan.state {
		case .changed:
			view.transform = CGAffineTransform(translationX: 0, y: translation)
			view.alpha = max(0.4, 1 - abs(translation) / view.bounds.height)
		case .ended:
			let velocity = pan.velocity(in: view).y
			if MediaSwipeDismiss.shouldDismiss(translation: translation, velocity: velocity, height: view.bounds.height) {
				finish(view, direction: translation == 0 ? velocity : translation)
			} else {
				restore(view)
			}
		case .cancelled, .failed:
			restore(view)
		default:
			break
		}
	}

	private func finish(_ view: UIView, direction: CGFloat) {
		isDismissing = true
		let offset = (direction < 0 ? -1 : 1) * view.bounds.height
		UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseIn, .beginFromCurrentState], animations: {
			view.transform = CGAffineTransform(translationX: 0, y: offset)
			view.alpha = 0
		}, completion: { [weak self] _ in
			self?.onDismiss()
			// The controller is gone (or kept by Picture in Picture); leave the view reusable.
			view.transform = .identity
			view.alpha = 1
			self?.isDismissing = false
		})
	}

	private func restore(_ view: UIView) {
		UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
			view.transform = .identity
			view.alpha = 1
		})
	}
}
