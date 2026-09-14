//
//  ArticleMediaSaver.swift
//  NetNewsWire-iOS
//

import Foundation
import Photos
import ImageIO
import UniformTypeIdentifiers
import ErrorLog

@MainActor
final class ArticleMediaSaver {

	struct Result {
		let requestedCount: Int
		var savedCount = 0
		var failedCount = 0
		var skippedCount: Int
	}

	private enum SaveError: Error {
		case invalidSource
		case unsupportedVideo
		case unsuccessfulResponse
		case undecodableImage
	}

	private let session: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configuration.httpShouldSetCookies = false
		configuration.httpCookieAcceptPolicy = .never
		return URLSession(configuration: configuration)
	}()

	func authorize() async -> Bool {
		let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
		ArticleMediaLog.log(.debug, operation: "Photo Library", message: "Add-only authorization status before request: \(Self.describe(status))")
		switch status {
		case .authorized, .limited:
			return true
		case .notDetermined:
			let granted = await Self.requestAddOnlyAuthorization()
			ArticleMediaLog.log(.debug, operation: "Photo Library", message: "Add-only authorization after request: \(granted ? "granted" : "denied")")
			return granted
		default:
			return false
		}
	}

	func saveImages(sources: [String], iconData: Data?, skippedCount: Int, progress: @escaping @MainActor (Int, Int) -> Void) async -> Result {
		var result = Result(requestedCount: sources.count, skippedCount: skippedCount)

		for (index, source) in sources.enumerated() {
			let position = index + 1
			ArticleMediaLog.log(.debug, operation: "Save all", message: "Image \(position)/\(sources.count) begin: \(ArticleMediaLog.urlDescription(source, level: .debug))")
			ArticleMediaSaveStage.update("image:\(position)/\(sources.count):fetching")
			do {
				let data = try await imageData(for: source, iconData: iconData)
				let type = Self.imageTypeDescription(data)
				ArticleMediaLog.log(.debug, operation: "Save all", message: "Image \(position)/\(sources.count) fetched \(data.count) bytes; type \(type)")
				ArticleMediaSaveStage.update("image:\(position)/\(sources.count):saving \(data.count) bytes \(type)")

				let fileURL = try Self.writeTemporaryImage(data, typeIdentifier: type)
				defer { try? FileManager.default.removeItem(at: fileURL) }

				try await saveImage(at: fileURL)
				result.savedCount += 1
				ArticleMediaLog.log(.debug, operation: "Save all", message: "Image \(position)/\(sources.count) saved to the photo library")
			} catch SaveError.undecodableImage {
				result.skippedCount += 1
				ArticleMediaLog.log(.warning, operation: "Save all", message: "Image \(position)/\(sources.count) is not a decodable image; skipped (\(ArticleMediaLog.urlDescription(source, level: .warning)))")
			} catch {
				result.failedCount += 1
				ArticleMediaLog.log(.warning, operation: "Save all", message: "Image \(position)/\(sources.count) failed: \(error.localizedDescription)")
			}
			progress(position, sources.count)
		}

		return result
	}

	func saveVideos(sources: [String], skippedCount: Int, progress: @escaping @MainActor (Int, Int) -> Void) async -> Result {
		var result = Result(requestedCount: sources.count, skippedCount: skippedCount)

		for (index, source) in sources.enumerated() {
			let position = index + 1
			ArticleMediaLog.log(.debug, operation: "Save all", message: "Video \(position)/\(sources.count) begin: \(ArticleMediaLog.urlDescription(source, level: .debug))")
			ArticleMediaSaveStage.update("video:\(position)/\(sources.count):downloading")
			var downloadedURL: URL?
			defer {
				if let downloadedURL {
					try? FileManager.default.removeItem(at: downloadedURL)
				}
			}
			do {
				let fileURL = try await downloadVideo(source)
				downloadedURL = fileURL
				let size = Self.fileSize(at: fileURL)
				ArticleMediaLog.log(.debug, operation: "Save all", message: "Video \(position)/\(sources.count) downloaded \(size) bytes")

				let videoURL = try Self.moveTemporaryVideo(fileURL)
				downloadedURL = videoURL
				ArticleMediaSaveStage.update("video:\(position)/\(sources.count):saving \(size) bytes")

				try await saveVideo(at: videoURL)
				result.savedCount += 1
				ArticleMediaLog.log(.debug, operation: "Save all", message: "Video \(position)/\(sources.count) saved to the photo library")
			} catch SaveError.unsupportedVideo {
				result.skippedCount += 1
				ArticleMediaLog.log(.warning, operation: "Save all", message: "Video \(position)/\(sources.count) is a streaming playlist; skipped (\(ArticleMediaLog.urlDescription(source, level: .warning)))")
			} catch {
				result.failedCount += 1
				ArticleMediaLog.log(.warning, operation: "Save all", message: "Video \(position)/\(sources.count) failed: \(error.localizedDescription)")
			}
			progress(position, sources.count)
		}

		return result
	}
}

private extension ArticleMediaSaver {

	static func describe(_ status: PHAuthorizationStatus) -> String {
		switch status {
		case .notDetermined: "notDetermined"
		case .restricted: "restricted"
		case .denied: "denied"
		case .authorized: "authorized"
		case .limited: "limited"
		@unknown default: "unknown(\(status.rawValue))"
		}
	}

	/// The image's uniform type identifier, or an empty string when the data is not a decodable image.
	///
	/// PhotoKit aborts the process with an Objective-C exception when it is handed data it cannot
	/// treat as an image, and that exception cannot be caught in Swift, so undecodable data must be
	/// rejected here. SVG, HTML error pages, and empty responses all fail this check.
	static func imageTypeDescription(_ data: Data) -> String {
		guard !data.isEmpty,
			let source = CGImageSourceCreateWithData(data as CFData, nil),
			CGImageSourceGetCount(source) > 0,
			let type = CGImageSourceGetType(source) else {
			return ""
		}
		return type as String
	}

	static func fileSize(at fileURL: URL) -> Int {
		let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
		return (attributes?[.size] as? Int) ?? 0
	}

	/// Writes the data to a temporary file whose extension matches its type, because PhotoKit infers
	/// the resource type from the file extension.
	static func writeTemporaryImage(_ data: Data, typeIdentifier: String) throws -> URL {
		guard !typeIdentifier.isEmpty else {
			throw SaveError.undecodableImage
		}
		let fileURL = temporaryFileURL(typeIdentifier: typeIdentifier)
		try data.write(to: fileURL, options: .atomic)
		return fileURL
	}

	static func moveTemporaryVideo(_ fileURL: URL) throws -> URL {
		let typeIdentifier = UTType(filenameExtension: fileURL.pathExtension)?.identifier
			?? UTType.mpeg4Movie.identifier
		let destination = temporaryFileURL(typeIdentifier: typeIdentifier)
		try FileManager.default.moveItem(at: fileURL, to: destination)
		return destination
	}

	static func temporaryFileURL(typeIdentifier: String) -> URL {
		let fileExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? "dat"
		return FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
			.appendingPathExtension(fileExtension)
	}

	func imageData(for source: String, iconData: Data?) async throws -> Data {
		if source.lowercased().hasPrefix("nnwimageicon:"), let iconData {
			return iconData
		}
		if source.lowercased().hasPrefix("data:image/") {
			return try dataURLData(source)
		}

		guard let url = URL(string: source), url.scheme == "http" || url.scheme == "https" else {
			throw SaveError.invalidSource
		}

		let (data, response) = try await session.data(from: url)
		try validate(response)
		return data
	}

	func downloadVideo(_ source: String) async throws -> URL {
		guard let url = URL(string: source), url.scheme == "http" || url.scheme == "https" else {
			throw SaveError.invalidSource
		}

		let (fileURL, response) = try await session.download(from: url)
		try validate(response)
		if response.mimeType?.lowercased().contains("mpegurl") == true {
			throw SaveError.unsupportedVideo
		}
		return fileURL
	}

	func dataURLData(_ source: String) throws -> Data {
		guard let commaIndex = source.firstIndex(of: ",") else {
			throw SaveError.invalidSource
		}

		let header = source[..<commaIndex]
		let payload = String(source[source.index(after: commaIndex)...])
		if header.lowercased().contains(";base64"), let data = Data(base64Encoded: payload) {
			return data
		}
		if let decodedPayload = payload.removingPercentEncoding, let data = decodedPayload.data(using: .utf8) {
			return data
		}
		throw SaveError.invalidSource
	}

	func validate(_ response: URLResponse) throws {
		guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
			throw SaveError.unsuccessfulResponse
		}
	}

	func saveImage(at fileURL: URL) async throws {
		try await Self.saveToPhotoLibrary { [url = fileURL] in
			let request = PHAssetCreationRequest.forAsset()
			request.addResource(with: .photo, fileURL: url, options: nil)
		}
	}

	func saveVideo(at fileURL: URL) async throws {
		try await Self.saveToPhotoLibrary { [url = fileURL] in
			let request = PHAssetCreationRequest.forAsset()
			request.addResource(with: .video, fileURL: url, options: nil)
		}
	}
}

private extension ArticleMediaSaver {

	/// Asks for add-only Photos access.
	///
	/// Like the change block below, this lives outside the actor: PhotoKit answers on a queue of
	/// its own choosing, and an inherited main-actor isolation would put a runtime executor check
	/// on that queue.
	nonisolated static func requestAddOnlyAuthorization() async -> Bool {
		await withCheckedContinuation { continuation in
			PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
				continuation.resume(returning: status == .authorized || status == .limited)
			}
		}
	}

	/// Runs `changes` inside a PhotoKit change block.
	///
	/// This is deliberately `nonisolated`: PhotoKit executes the change block on an arbitrary
	/// serial queue, and a block that inherited this type's main-actor isolation would trip the
	/// Swift runtime's executor check on that queue. Marking the block `@Sendable` alone is not
	/// enough — a main-actor context still propagates into it — so the PhotoKit call itself has to
	/// live outside the actor.
	nonisolated static func saveToPhotoLibrary(_ changes: @escaping @Sendable () -> Void) async throws {
		try await withCheckedThrowingContinuation { continuation in
			PHPhotoLibrary.shared().performChanges {
				changes()
			} completionHandler: { success, error in
				if success {
					continuation.resume()
				} else {
					continuation.resume(throwing: error ?? SaveError.unsuccessfulResponse)
				}
			}
		}
	}
}
