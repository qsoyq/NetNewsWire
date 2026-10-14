//
//  ImageDownloader.swift
//  Images
//
//  Created by Brent Simmons on 11/25/17.
//  Copyright © 2017 Ranchero Software. All rights reserved.
//

import Foundation
import os
import RSCore
import RSWeb
import ActivityLog

extension Notification.Name {
	public static let imageDidBecomeAvailable = Notification.Name("ImageDidBecomeAvailableNotification") // userInfo key: "url"
}

public struct ImageDownloadError: Error {
	public let statusCode: Int?
	public let decodingFailed: Bool
	public let isTransient: Bool
}

extension ImageDownloadError: LocalizedError {
	public var errorDescription: String? {
		if decodingFailed {
			if let statusCode {
				return "Couldn’t decode image bytes (HTTP \(statusCode))"
			}
			return "Couldn’t decode image bytes"
		}
		guard let statusCode else {
			return isTransient ? "No response" : "Bad URL"
		}
		return "HTTP \(statusCode)"
	}
}

public enum ImageCacheSettings {
	public static let lifetime: TimeInterval = 3 * 24 * 60 * 60
}

@MainActor public final class ImageDownloader {
	public static let shared = ImageDownloader(cacheSubfolderName: "Images")

	nonisolated static private let logger = Logger(subsystem: Logger.nnwSubsystem, category: "ImageDownloader")
	private struct CachedImage {
		let data: Data
		let date: Date
	}

	nonisolated private let diskCache: BinaryDiskCache
	private let queue: DispatchQueue
	private let now: @MainActor () -> Date
	private let download: @MainActor (URLRequest) async throws -> DownloadResponse
	private var imageCache = [String: CachedImage]()
	private var urlsInProgress = Set<String>()
	private var retryDates = [String: Date]()
	private var generation = UUID()
	private let cacheLifetime = ImageCacheSettings.lifetime

	init(cacheSubfolderName: String) {
		let folder = AppConfig.cacheSubfolder(named: cacheSubfolderName)
		self.diskCache = BinaryDiskCache(folder: folder.path)
		self.queue = DispatchQueue(label: "ImageDownloader serial queue - \(folder.path)")
		self.now = { Date() }
		self.download = { try await Downloader.shared.download($0, userAgentStyle: .browser) }
		observeNotifications()
	}

	// A real temporary cache and local transport can exercise expiration without waiting three days.
	init(diskCache: BinaryDiskCache, now: @escaping @MainActor () -> Date,
		 download: @escaping @MainActor (URLRequest) async throws -> DownloadResponse) {
		self.diskCache = diskCache
		self.queue = DispatchQueue(label: "ImageDownloader test cache - \(diskCache.folder)")
		self.now = now
		self.download = download
		observeNotifications()
	}

	private func observeNotifications() {
		NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidGoToBackground(_:)), name: .appDidGoToBackground, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(handleLowMemory(_:)), name: .lowMemory, object: nil)
	}

	@objc func handleAppDidGoToBackground(_ notification: Notification) {
		imageCache.removeAll()
	}

	@objc func handleLowMemory(_ notification: Notification) {
		imageCache.removeAll()
	}

	func isFresh(_ url: String) -> Bool {
		guard let cached = imageCache[url] else {
			return false
		}
		return now().timeIntervalSince(cached.date) < cacheLifetime
	}

	/// Invalidate both memory and disk. Queued disk work finishes before deletion; old downloads
	/// are discarded by the generation check and cannot refill a cache the user just cleared.
	public func clearCache() async throws {
		generation = UUID()
		imageCache.removeAll()
		retryDates.removeAll()
		urlsInProgress.removeAll()
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			queue.async {
				do {
					let folder = self.diskCache.folder
					if FileManager.default.fileExists(atPath: folder) {
						try FileManager.default.removeItem(atPath: folder)
					}
					try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
					continuation.resume()
				} catch {
					continuation.resume(throwing: error)
				}
			}
		}
	}

	/// Returns the last image immediately, revalidating expired bytes in the background.
	@discardableResult
	public func image(for url: String, activityOwner: ActivityOwner? = nil, activityKind: ActivityKind? = nil, activityDetail: String? = nil) -> Data? {
		guard url.hasPrefix("http://") || url.hasPrefix("https://") else {
			return nil
		}
		let cached = imageCache[url]
		if isFresh(url) {
			return cached?.data
		}
		if let retryDate = retryDates[url], now() < retryDate {
			return cached?.data
		}
		if ImageMetadataDatabase.shared.recentlyFailed(url: url) {
			return cached?.data
		}
		let currentGeneration = generation
		Task { @MainActor in
			guard currentGeneration == self.generation else {
				return
			}
			await self.findImage(url, activityOwner: activityOwner, activityKind: activityKind, activityDetail: activityDetail)
		}
		return cached?.data
	}
}

private extension ImageDownloader {
	func cacheImage(_ url: String, _ image: Data, date: Date) {
		imageCache[url] = CachedImage(data: image, date: date)
		NotificationCenter.default.post(name: .imageDidBecomeAvailable, object: self, userInfo: ["url": url])
	}

	func findImage(_ url: String, activityOwner: ActivityOwner?, activityKind: ActivityKind?, activityDetail: String?) async {
		guard !urlsInProgress.contains(url), !isFresh(url) else {
			return
		}
		let currentGeneration = generation
		urlsInProgress.insert(url)
		defer {
			if currentGeneration == generation {
				urlsInProgress.remove(url)
			}
		}

		if imageCache[url] == nil, let cached = await readFromDisk(url: url) {
			guard currentGeneration == generation else {
				return
			}
			cacheImage(url, cached.data, date: cached.date)
			if isFresh(url) {
				return
			}
		}
		guard currentGeneration == generation else {
			return
		}

		let activityLog = ActivityLog.shared
		if let activityOwner, let activityKind {
			activityLog.createActivity(owner: activityOwner, kind: activityKind, detail: activityDetail)
			activityLog.didStart(activityOwner, kind: activityKind)
		}
		do {
			let (image, response) = try await downloadImage(url)
			if let activityOwner, let activityKind {
				activityLog.didComplete(activityOwner, kind: activityKind, message: response.data.map(ActivityLog.dataSizeMessage), returnedFromCache: response.returnedFromCache)
			}
			guard currentGeneration == generation else {
				return
			}
			let date = now()
			saveToDisk(url, image, date: date)
			retryDates[url] = nil
			cacheImage(url, image, date: date)
			ImageMetadataDatabase.shared.clearFailure(url: url)
		} catch {
			if let activityOwner, let activityKind {
				activityLog.didFail(activityOwner, kind: activityKind, error: error)
			}
			guard currentGeneration == generation else {
				return
			}
			retryDates[url] = now().addingTimeInterval(30 * 60)
			if !error.isTransient {
				ImageMetadataDatabase.shared.recordFailure(url: url, statusCode: error.statusCode)
			}
		}
	}

	private func readFromDisk(url: String) async -> CachedImage? {
		await withCheckedContinuation { continuation in
			queue.async {
				let cached = try? self.diskCache.dataAndModificationDate(forKey: url.md5String)
				let result = cached.flatMap { $0.data.isEmpty ? nil : CachedImage(data: $0.data, date: $0.modificationDate) }
				continuation.resume(returning: result)
			}
		}
	}

	func downloadImage(_ url: String) async throws(ImageDownloadError) -> (Data, DownloadResponse) {
		guard let imageURL = URL(string: url) else {
			throw ImageDownloadError(statusCode: nil, decodingFailed: false, isTransient: false)
		}
		var request = URLRequest(url: imageURL)
		request.cachePolicy = .reloadIgnoringLocalCacheData
		let response: DownloadResponse
		do {
			response = try await download(request)
		} catch {
			throw ImageDownloadError(statusCode: nil, decodingFailed: false, isTransient: true)
		}
		if let data = response.data, !data.isEmpty, let httpResponse = response.response, httpResponse.statusIsOK {
			let scaledData = RSImage.scaledImageData(data, maxPixelSize: RSImage.maxIconPixelSize) ?? data
			guard await RSImage.image(data: scaledData) != nil else {
				throw ImageDownloadError(statusCode: (httpResponse as? HTTPURLResponse)?.statusCode, decodingFailed: true, isTransient: false)
			}
			return (scaledData, response)
		}
		let statusCode = (response.response as? HTTPURLResponse)?.statusCode
		throw ImageDownloadError(statusCode: statusCode, decodingFailed: false, isTransient: statusCode.map { (500...599).contains($0) } ?? true)
	}

	func saveToDisk(_ url: String, _ data: Data, date: Date) {
		queue.async {
			self.diskCache[url.md5String] = data
			let path = (self.diskCache.folder as NSString).appendingPathComponent(url.md5String)
			try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
		}
	}
}
