//
//  ImageViewController.swift
//  NetNewsWire-iOS
//
//  Created by Maurice Parker on 10/12/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import UIKit

final class ImageViewController: UIViewController {
	@IBOutlet var closeButton: UIButton!
	@IBOutlet var shareButton: UIButton!
	@IBOutlet var imageScrollView: ImageScrollView!
	@IBOutlet var titleLabel: UILabel!
	@IBOutlet var titleBackground: UIVisualEffectView!
	@IBOutlet var titleLeading: NSLayoutConstraint!
	@IBOutlet var titleTrailing: NSLayoutConstraint!

	var image: UIImage!
	var imageTitle: String?
	var saveAllImagesHandler: (() -> Void)?
	var zoomedFrame: CGRect {
		return imageScrollView.zoomedFrame
	}

	override var keyCommands: [UIKeyCommand]? {
		return [
			UIKeyCommand(
				title: NSLocalizedString("Close Image", comment: "Close Image"),
				action: #selector(done(_:)),
				input: " "
			)
		]
	}

	override func viewDidLoad() {
        super.viewDidLoad()

		closeButton.imageView?.contentMode = .scaleAspectFit
		closeButton.accessibilityLabel = NSLocalizedString("Close", comment: "Close")
		shareButton.accessibilityLabel = NSLocalizedString("Share", comment: "Share")

        imageScrollView.setup()
        imageScrollView.imageScrollViewDelegate = self
        imageScrollView.imageContentMode = .aspectFit
		imageScrollView.initialOffset = .center
		imageScrollView.display(image: image)
		if let zoomView = imageScrollView.zoomView {
			let longPress = UILongPressGestureRecognizer(target: self, action: #selector(showImageActions(_:)))
			longPress.minimumPressDuration = 0.4
			zoomView.addGestureRecognizer(longPress)
		}

		titleLabel.text = imageTitle ?? ""
		layoutTitleLabel()

		guard imageTitle != "" else {
			titleBackground.removeFromSuperview()
			return
		}
		titleBackground.layer.cornerRadius = 6
    }

	override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
		super.viewWillTransition(to: size, with: coordinator)
		coordinator.animate(alongsideTransition: { [weak self] _ in
			self?.imageScrollView.resize()
		})
	}

	@IBAction func share(_ sender: Any) {
		guard let image = image else { return }
		let activityViewController = UIActivityViewController(activityItems: [image], applicationActivities: nil)
		activityViewController.popoverPresentationController?.sourceView = shareButton
		activityViewController.popoverPresentationController?.sourceRect = shareButton.bounds
		present(activityViewController, animated: true)
	}

	@IBAction func done(_ sender: Any) {
		dismiss(animated: true)
	}

	@objc private func saveToPhotos() {
		UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
	}

	@objc private func showImageActions(_ gestureRecognizer: UILongPressGestureRecognizer) {
		guard gestureRecognizer.state == .began else {
			return
		}

		let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
		alert.addAction(UIAlertAction(title: NSLocalizedString("Share", comment: "Share"), style: .default) { [weak self] _ in
			guard let self, let shareButton = self.shareButton else {
				return
			}
			self.share(shareButton)
		})
		alert.addAction(UIAlertAction(title: NSLocalizedString("Save to Photos", comment: "Save image to Photos"), style: .default) { [weak self] _ in
			self?.saveToPhotos()
		})
		if saveAllImagesHandler != nil {
			alert.addAction(UIAlertAction(title: NSLocalizedString("Save All Images", comment: "Save all article images"), style: .default) { [weak self] _ in
				self?.dismiss(animated: true) {
					self?.saveAllImagesHandler?()
				}
			})
		}
		alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel"), style: .cancel))
		alert.popoverPresentationController?.sourceView = imageScrollView
		let location = gestureRecognizer.location(in: imageScrollView)
		alert.popoverPresentationController?.sourceRect = CGRect(origin: location, size: .zero)
		present(alert, animated: true)
	}

	private func layoutTitleLabel() {
		let width = view.frame.width
		let multiplier = traitCollection.userInterfaceIdiom == .pad ? CGFloat(0.1) : CGFloat(0.04)
		titleLeading.constant += width * multiplier
		titleTrailing.constant -= width * multiplier
		titleLabel.layoutIfNeeded()
	}
}

// MARK: ImageScrollViewDelegate

extension ImageViewController: ImageScrollViewDelegate {

	func imageScrollViewDidGestureSwipeUp(imageScrollView: ImageScrollView) {
		dismiss(animated: true)
	}

	func imageScrollViewDidGestureSwipeDown(imageScrollView: ImageScrollView) {
		dismiss(animated: true)
	}
}
