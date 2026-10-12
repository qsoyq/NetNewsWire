import Foundation
@preconcurrency import AVFoundation
import UIKit

actor VideoPreviewService {
	static let shared = VideoPreviewService()

	enum Priority: Int, Sendable { case current, prefetch }
	struct Unavailable: Error, Sendable { let statusCode: Int }
	private struct Failure {
		let error: Unavailable
		let expires: Date
	}
	private var failures: [URL: Failure] = [:]
	private let failureLifetime: TimeInterval
	private let probe: @Sendable (URL) async throws -> Int?
	private struct Job {
		let id = UUID()
		var priority: Priority
		var waiters: [UUID: CheckedContinuation<Data, Error>] = [:]
		var task: Task<Void, Never>?
	}

	private let cache: VideoPreviewCache
	private let generate: @Sendable (URL) async throws -> Data
	private var jobs: [URL: Job] = [:]
	private var queue: [URL] = []
	private var active = Set<UUID>()
	var pendingRequestCount: Int { jobs.values.reduce(0) { $0 + $1.waiters.count } }
	var queuedJobCount: Int { queue.count }

	init(cache: VideoPreviewCache = .shared, failureLifetime: TimeInterval = 300,
		 generate: (@Sendable (URL) async throws -> Data)? = nil,
		 probe: (@Sendable (URL) async throws -> Int?)? = nil) {
		self.cache = cache
		self.failureLifetime = failureLifetime
		let usesDefaultGenerator = generate == nil
		self.generate = generate ?? { url in try await VideoPreviewService.generatePreview(for: url) }
		if let probe {
			self.probe = probe
		} else if usesDefaultGenerator {
			self.probe = { url in try await VideoPreviewService.probeStatus(for: url) }
		} else {
			// Custom generators used by tests do not access the network unless requested.
			self.probe = { _ in nil }
		}
	}

	func preview(for url: URL, priority: Priority = .current) async throws -> Data {
		try Task.checkCancellation()
		if let data = await cache.data(for: url) {
			try Task.checkCancellation()
			return data
		}
		failures = failures.filter { $0.value.expires > Date() }
		if !VideoCacheDatabase.shared.hasCachedData(for: url.absoluteString), let failure = failures[url] {
			throw failure.error
		}
		let waiter = UUID()
		return try await withTaskCancellationHandler {
			try Task.checkCancellation()
			return try await withCheckedThrowingContinuation { continuation in
				if jobs[url] == nil {
					jobs[url] = Job(priority: priority)
					queue.append(url)
				}
				jobs[url]?.waiters[waiter] = continuation
				if priority == .current { jobs[url]?.priority = .current }
				startNextJobs()
			}
		} onCancel: {
			Task { await self.cancel(url: url, waiter: waiter) }
		}
	}

	func clearCache() async {
		cancelAll()
		failures.removeAll()
		await cache.clear()
	}

	func cancelAll() {
		for job in jobs.values {
			job.task?.cancel()
			for waiter in job.waiters.values { waiter.resume(throwing: CancellationError()) }
		}
		jobs.removeAll()
		queue.removeAll()
	}

	private func cancel(url: URL, waiter: UUID) {
		guard var job = jobs[url], let continuation = job.waiters.removeValue(forKey: waiter) else { return }
		continuation.resume(throwing: CancellationError())
		if job.waiters.isEmpty {
			job.task?.cancel()
			jobs.removeValue(forKey: url)
			queue.removeAll { $0 == url }
		} else {
			jobs[url] = job
		}
		startNextJobs()
	}

	private func startNextJobs() {
		while active.count < 2, !queue.isEmpty {
			let index = queue.firstIndex { jobs[$0]?.priority == .current } ?? 0
			let url = queue.remove(at: index)
			guard let job = jobs[url] else { continue }
			let id = job.id
			active.insert(id)
			jobs[url]?.task = Task(priority: job.priority == .current ? .userInitiated : .utility) {
				let result: Result<Data, Error>
				do {
					let epoch = await cache.epoch()
					try Task.checkCancellation()
					if !VideoCacheDatabase.shared.hasCachedData(for: url.absoluteString) {
						do {
							if let status = try await probe(url), status == 404 || status == 410 {
								throw Unavailable(statusCode: status)
							}
						} catch let error as Unavailable {
							throw error
						} catch {
							try Task.checkCancellation()
							// A probe failure is not proof that playback will fail.
						}
					}
					try Task.checkCancellation()
					let data = try await generate(url)
					try Task.checkCancellation()
					await cache.store(data, for: url, epoch: epoch)
					try Task.checkCancellation()
					result = .success(data)
				} catch { result = .failure(error) }
				finish(url: url, id: id, result: result)
			}
		}
	}

	private func finish(url: URL, id: UUID, result: Result<Data, Error>) {
		active.remove(id)
		if let job = jobs[url], job.id == id {
			jobs.removeValue(forKey: url)
			if case .failure(let error as Unavailable) = result {
				if failures.count >= 256, let oldest = failures.min(by: { $0.value.expires < $1.value.expires })?.key {
					failures.removeValue(forKey: oldest)
				}
				failures[url] = Failure(error: error, expires: Date().addingTimeInterval(failureLifetime))
			}
			for waiter in job.waiters.values { waiter.resume(with: result) }
		}
		startNextJobs()
	}

	@concurrent static func probeStatus(for url: URL) async throws -> Int? {
		guard url.scheme == "http" || url.scheme == "https" else {
			return nil
		}
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = 3
		configuration.timeoutIntervalForResource = 3
		let session = URLSession(configuration: configuration)
		defer { session.invalidateAndCancel() }
		var request = URLRequest(url: url)
		request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
		// Inspect only headers. Cancellation also bounds servers that ignore Range.
		let (_, response) = try await session.bytes(for: request)
		try Task.checkCancellation()
		return (response as? HTTPURLResponse)?.statusCode
	}

	@concurrent static func generatePreview(for url: URL, timeout: Duration = .seconds(30)) async throws -> Data {
		var temporaryFile: URL?
		var assetURL = url
		// Reuse an existing full-video cache without initiating a full download.
		if let cached = VideoCacheDatabase.shared.cachedData(for: url.absoluteString) {
			let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
			try cached.data.write(to: file, options: .atomic)
			temporaryFile = file
			assetURL = file
		}
		defer { if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) } }
		try Task.checkCancellation()
		let operation = VideoPreviewImageOperation(url: assetURL)
		return try await withTaskCancellationHandler {
			try await withThrowingTaskGroup(of: Data.self) { group in
				group.addTask { try await operation.jpeg() }
				group.addTask {
					try await Task.sleep(for: timeout)
					operation.cancel()
					throw URLError(.timedOut)
				}
				defer { group.cancelAll() }
				guard let data = try await group.next() else { throw CancellationError() }
				return data
			}
		} onCancel: { operation.cancel() }
	}
}

// The generator is configured once. AVFoundation's cancellation API is the only
// cross-task operation; no mutable application state crosses the boundary.
private final class VideoPreviewImageOperation: @unchecked Sendable {
	private let generator: AVAssetImageGenerator
	init(url: URL) {
		generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
		generator.appliesPreferredTrackTransform = true
		generator.maximumSize = CGSize(width: 720, height: 720)
	}
	func cancel() { generator.cancelAllCGImageGeneration() }
	func jpeg() async throws -> Data {
		try Task.checkCancellation()
		let result = try await generator.image(at: .zero)
		try Task.checkCancellation()
		guard let data = UIImage(cgImage: result.image).jpegData(compressionQuality: 0.8) else { throw URLError(.cannotDecodeContentData) }
		return data
	}
}
