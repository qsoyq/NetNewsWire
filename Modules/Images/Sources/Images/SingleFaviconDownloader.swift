//
//  SingleFaviconDownloader.swift
//  Images
//
//  Created by Brent Simmons on 11/23/17.
//

import Foundation
import ActivityLog
import RSCore
import RSWeb

extension Notification.Name {
	public static let DidLoadFavicon = Notification.Name("DidLoadFaviconNotification")
}

/// Favicon decoding shares the same expiration and refresh policy as feed images and avatars.
@MainActor public final class SingleFaviconDownloader {
	static let imageDownloader = ImageDownloader(cacheSubfolderName: "Favicons")
	public let faviconURL: String
	public let homePageURL: String?
	public private(set) var iconImage: IconImage?
	public private(set) var error: ImageDownloadError?
	private var lastImageData: Data?
	private var generation = UUID()

	public init(faviconURL: String, homePageURL: String?, diskCache: BinaryDiskCache, queue: DispatchQueue) {
		self.faviconURL = faviconURL
		self.homePageURL = homePageURL
		NotificationCenter.default.addObserver(self, selector: #selector(imageDidBecomeAvailable(_:)), name: .imageDidBecomeAvailable, object: Self.imageDownloader)
		_ = downloadFaviconIfNeeded()
	}

	public func downloadFaviconIfNeeded() -> Bool {
		let isFresh = Self.imageDownloader.isFresh(faviconURL)
		if let data = Self.imageDownloader.image(for: faviconURL, activityOwner: .faviconDownloader,
			activityKind: .downloadFavicon(faviconURL: faviconURL), activityDetail: homePageURL) {
			decode(data)
		}
		return !isFresh
	}

	func invalidate() {
		generation = UUID()
		NotificationCenter.default.removeObserver(self)
		iconImage = nil
		lastImageData = nil
	}

	@objc private func imageDidBecomeAvailable(_ notification: Notification) {
		guard notification.userInfo?["url"] as? String == faviconURL,
			let data = Self.imageDownloader.image(for: faviconURL) else {
			return
		}
		decode(data)
	}

	private func decode(_ data: Data) {
		guard data != lastImageData else {
			return
		}
		lastImageData = data
		let currentGeneration = generation
		RSImage.image(with: data) { image in
			guard currentGeneration == self.generation, let image else {
				return
			}
			self.iconImage = IconImage(image)
			self.error = nil
			NotificationCenter.default.post(name: .DidLoadFavicon, object: self)
		}
	}
}
