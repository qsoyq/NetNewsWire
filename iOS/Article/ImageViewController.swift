//
//  ImageViewController.swift
//  NetNewsWire-iOS
//
//  Created by Maurice Parker on 10/12/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

import UIKit
import RSWeb

struct ArticleGalleryImage: Codable {
	let url: String
	let title: String
}

final class ImageViewController: UIViewController {
	@IBOutlet var imageScrollView: ImageScrollView!
	@IBOutlet var titleLabel: UILabel!
	@IBOutlet var titleBackground: UIVisualEffectView!
	@IBOutlet var titleLeading: NSLayoutConstraint!
	@IBOutlet var titleTrailing: NSLayoutConstraint!

	private var shareButtonItem: UIBarButtonItem?
	var gallery: [ArticleGalleryImage] = []
	private(set) var galleryIndex = 0
	private var requestedIndex = 0
	private var galleryTask: Task<Void, Never>?
	private let gallerySpinner = UIActivityIndicatorView(style: .large)
	private let galleryStatus = UILabel()
	private var galleryGeneration = 0

	var image: UIImage!
	var imageTitle: String?
	var resourceURL: String?
	var saveAllImagesHandler: (() -> Void)?

	// Strong reference — the navigation controller’s transitioningDelegate is weak,
	// and the transition must outlive the WebViewController that configured it.
	var transition: ImageTransition?
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

		let closeButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(done(_:)))
		closeButtonItem.tintColor = Assets.Colors.primaryAccent
		let shareButtonItem = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(share(_:)))
		shareButtonItem.tintColor = Assets.Colors.primaryAccent
		navigationItem.leftBarButtonItem = closeButtonItem
		navigationItem.rightBarButtonItem = shareButtonItem
		self.shareButtonItem = shareButtonItem

        imageScrollView.setup()
        // The image viewer is full-screen, so the scroll view ignores
        // the navigation bar and safe area insets. Otherwise the image is pushed down
        // and doesn’t match the zoom transition’s target frame.
        imageScrollView.contentInsetAdjustmentBehavior = .never
        imageScrollView.imageScrollViewDelegate = self
        imageScrollView.imageContentMode = .aspectFit
		imageScrollView.initialOffset = .center
		imageScrollView.display(image: image)
		installImageActions()
		galleryIndex = gallery.firstIndex { $0.url == resourceURL } ?? 0
		requestedIndex = galleryIndex
		if gallery.count > 1 {
			for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
				let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipeImage(_:)))
				swipe.direction = direction
				swipe.delegate = self
				view.addGestureRecognizer(swipe)
				imageScrollView.panGestureRecognizer.require(toFail: swipe)
			}
			navigationItem.title = "\(galleryIndex + 1) / \(gallery.count)"
		}
		gallerySpinner.translatesAutoresizingMaskIntoConstraints = false
		gallerySpinner.hidesWhenStopped = true
		view.addSubview(gallerySpinner)
		galleryStatus.translatesAutoresizingMaskIntoConstraints = false
		galleryStatus.textColor = .secondaryLabel
		galleryStatus.font = .preferredFont(forTextStyle: .footnote)
		galleryStatus.numberOfLines = 0
		galleryStatus.textAlignment = .center
		view.addSubview(galleryStatus)
		NSLayoutConstraint.activate([
			gallerySpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			gallerySpinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
			galleryStatus.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
			galleryStatus.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
			galleryStatus.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
		])

		titleLabel.text = imageTitle ?? ""
		layoutTitleLabel()

		titleBackground.isHidden = imageTitle?.isEmpty != false
		titleBackground.layer.cornerRadius = 6
    }

	override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
		super.viewWillTransition(to: size, with: coordinator)
		coordinator.animate(alongsideTransition: { [weak self] _ in
			self?.imageScrollView.resize()
		})
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		if isBeingDismissed || navigationController?.isBeingDismissed == true {
			galleryGeneration += 1
			galleryTask?.cancel()
		}
	}

	private func installImageActions() {
		guard let zoomView = imageScrollView.zoomView else {
			return
		}
		let longPress = UILongPressGestureRecognizer(target: self, action: #selector(showImageActions(_:)))
		longPress.minimumPressDuration = 0.4
		zoomView.addGestureRecognizer(longPress)
	}

	@objc private func swipeImage(_ gesture: UISwipeGestureRecognizer) {
		showAdjacentImage(offset: gesture.direction == .left ? 1 : -1)
	}

	func showAdjacentImage(offset: Int) {
		let next = requestedIndex + offset
		guard gallery.indices.contains(next) else {
			return
		}
		galleryGeneration += 1
		let generation = galleryGeneration
		galleryTask?.cancel()
		requestedIndex = next
		gallerySpinner.startAnimating()
		galleryStatus.text = nil
		let item = gallery[next]
		galleryTask = Task { [weak self] in
			let data: Data?
			if item.url.hasPrefix("data:") {
				data = try? ArticleMediaSaver.dataURLData(item.url)
			} else if let url = URL(string: item.url), ["https", "http"].contains(url.scheme) {
				data = try? await Downloader.shared.download(url, userAgentStyle: .browser).data
			} else {
				data = nil
			}
			guard !Task.isCancelled, let self, self.galleryGeneration == generation else {
				return
			}
			self.gallerySpinner.stopAnimating()
			guard let data, let image = UIImage(data: data) else {
				self.requestedIndex = self.galleryIndex
				self.galleryStatus.text = NSLocalizedString("Unable to Load Image", comment: "Gallery image loading failure")
				return
			}
			self.galleryIndex = next
			self.image = image
			self.imageTitle = item.title
			self.resourceURL = item.url
			self.titleLabel.text = item.title
			self.titleBackground.isHidden = item.title.isEmpty
			self.navigationItem.title = "\(next + 1) / \(self.gallery.count)"
			self.transition?.returnsWithoutZoom = true
			UIView.transition(with: self.imageScrollView, duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2, options: .transitionCrossDissolve) {
				self.imageScrollView.display(image: image)
				self.installImageActions()
			}
		}
	}

	@IBAction func share(_ sender: Any) {
		guard let image else {
			return
		}
		let activityViewController = UIActivityViewController(activityItems: [image], applicationActivities: nil)
		activityViewController.popoverPresentationController?.barButtonItem = shareButtonItem
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
		if let resourceURL, !resourceURL.isEmpty {
			alert.addAction(UIAlertAction(title: NSLocalizedString("Copy Resource URL", comment: "Copy the original image or video URL"), style: .default) { _ in
				UIPasteboard.general.string = resourceURL
			})
		}
		alert.addAction(UIAlertAction(title: NSLocalizedString("Share", comment: "Share"), style: .default) { [weak self] _ in
			guard let self, let shareButton = self.shareButtonItem else {
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

extension ImageViewController: UIGestureRecognizerDelegate {
	func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
		imageScrollView.zoomScale <= imageScrollView.minimumZoomScale + 0.001
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
