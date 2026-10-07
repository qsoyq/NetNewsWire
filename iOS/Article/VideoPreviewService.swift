import Foundation
@preconcurrency import AVFoundation
import UIKit

actor VideoPreviewService {
	static let shared = VideoPreviewService()

	enum Priority: Int, Sendable { case current, prefetch }
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

	init(cache: VideoPreviewCache = .shared, generate: @escaping @Sendable (URL) async throws -> Data = { try await VideoPreviewService.generatePreview(for: $0) }) {
		self.cache = cache
		self.generate = generate
	}

	func preview(for url: URL, priority: Priority = .current) async throws -> Data {
		try Task.checkCancellation()
		if let data = await cache.data(for: url) {
			try Task.checkCancellation()
			return data
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
			for waiter in job.waiters.values { waiter.resume(with: result) }
		}
		startNextJobs()
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
