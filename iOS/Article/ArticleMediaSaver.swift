//
//  ArticleMediaSaver.swift
//  NetNewsWire-iOS
//

import Foundation
import Photos
import ErrorLog

@MainActor
final class ArticleMediaSaver {

	typealias Result = ArticleMediaSaveState.Result

	private enum SaveError: Error {
		case invalidSource
		case unsuccessfulResponse
	}

	private let session: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configuration.httpShouldSetCookies = false
		configuration.httpCookieAcceptPolicy = .never
		return URLSession(configuration: configuration)
	}()

	deinit {
		session.invalidateAndCancel()
	}

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
		await save(sources: sources, skippedCount: skippedCount, mediaType: "image", prepareFile: {
			try await self.imageFile(for: $0, iconData: iconData)
		}, saveFile: { try await self.saveImage(at: $0) }, progress: progress)
	}

	func saveVideos(sources: [String], skippedCount: Int, progress: @escaping @MainActor (Int, Int) -> Void) async -> Result {
		await save(sources: sources, skippedCount: skippedCount, mediaType: "video", prepareFile: {
			try await self.downloadVideo($0)
		}, saveFile: { try await self.saveVideo(at: $0) }, progress: progress)
	}
}

private extension ArticleMediaSaver {

	func save(sources: [String], skippedCount: Int, mediaType: String,
		prepareFile: @MainActor (String) async throws -> ArticleMediaFile,
		saveFile: @MainActor (URL) async throws -> Void,
		progress: @MainActor (Int, Int) -> Void) async -> Result {
		var state = ArticleMediaSaveState(requestedCount: sources.count, skippedCount: skippedCount)

		while let position = state.startNextItem(isCancelled: Task.isCancelled) {
			let source = sources[position - 1]
			ArticleMediaLog.log(.debug, operation: "Save all", message: "\(mediaType) \(position)/\(sources.count) begin: \(ArticleMediaLog.urlDescription(source, level: .debug))")
			ArticleMediaSaveStage.update("\(mediaType):\(position)/\(sources.count):preparing")
			do {
				let file = try await prepareFile(source)
				defer { try? FileManager.default.removeItem(at: file.url) }
				try Task.checkCancellation()
				ArticleMediaLog.log(.debug, operation: "Save all", message: "\(mediaType) \(position)/\(sources.count) prepared \(file.byteCount) bytes; type \(file.typeIdentifier)")
				ArticleMediaSaveStage.update("\(mediaType):\(position)/\(sources.count):saving \(file.byteCount) bytes \(file.typeIdentifier)")
				state.startPhotoLibrarySave()
				try await saveFile(file.url)
				// A cancelled task still waits for PhotoKit; its success must remain in the result.
				state.finishCurrentItem(.saved)
				ArticleMediaLog.log(.debug, operation: "Save all", message: "\(mediaType) \(position)/\(sources.count) saved to the photo library")
			} catch {
				if !state.isSavingToPhotoLibrary && (Task.isCancelled || ArticleMediaSaveState.isCancellation(error)) {
					state.cancelRemainingItems()
					ArticleMediaLog.log(.info, operation: "Save all", message: "\(mediaType) \(position)/\(sources.count) cancelled before saving")
					break
				}
				let isSkipped = !state.isSavingToPhotoLibrary && error is ArticleMediaFile.PreparationError
				state.finishCurrentItem(isSkipped ? .skipped : .failed)
				ArticleMediaLog.log(.warning, operation: "Save all", message: "\(mediaType) \(position)/\(sources.count) \(isSkipped ? "skipped" : "failed"): \(error.localizedDescription)")
			}
			progress(position, sources.count)
		}

		return state.result
	}

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

	func imageFile(for source: String, iconData: Data?) async throws -> ArticleMediaFile {
		try Task.checkCancellation()
		let prefix = source.prefix(32).lowercased()
		if prefix.hasPrefix("nnwimageicon:"), let iconData {
			return try await Self.prepareFile { try ArticleMediaFile.image(data: iconData) }
		}
		if prefix.hasPrefix("data:image/") {
			return try await Self.prepareFile {
				try ArticleMediaFile.image(data: Self.dataURLData(source))
			}
		}

		guard let url = URL(string: source), url.scheme == "http" || url.scheme == "https" else {
			throw SaveError.invalidSource
		}

		let (fileURL, response) = try await session.download(from: url)
		defer { try? FileManager.default.removeItem(at: fileURL) }
		try Task.checkCancellation()
		try validate(response)
		return try await Self.prepareFile { try ArticleMediaFile.image(downloadedURL: fileURL) }
	}

	func downloadVideo(_ source: String) async throws -> ArticleMediaFile {
		try Task.checkCancellation()
		guard let url = URL(string: source), url.scheme == "http" || url.scheme == "https" else {
			throw SaveError.invalidSource
		}

		let (fileURL, response) = try await session.download(from: url)
		defer { try? FileManager.default.removeItem(at: fileURL) }
		try Task.checkCancellation()
		try validate(response)
		let mimeType = response.mimeType
		return try await Self.prepareFile {
			try ArticleMediaFile.video(downloadedURL: fileURL, sourceURL: url, mimeType: mimeType)
		}
	}

	nonisolated static func prepareFile(_ prepare: @escaping @Sendable () throws -> ArticleMediaFile) async throws -> ArticleMediaFile {
		let task = Task.detached(priority: .utility) {
			try Task.checkCancellation()
			let file = try prepare()
			do {
				try Task.checkCancellation()
				return file
			} catch {
				try? FileManager.default.removeItem(at: file.url)
				throw error
			}
		}
		return try await withTaskCancellationHandler {
			try await task.value
		} onCancel: {
			task.cancel()
		}
	}

	nonisolated static func dataURLData(_ source: String) throws -> Data {
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
