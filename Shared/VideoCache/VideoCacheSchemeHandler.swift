//
//  VideoCacheSchemeHandler.swift
//  NetNewsWire
//
//  Created by NetNewsWire on 2026/04/13.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
@preconcurrency import WebKit
import os

final class VideoCacheSchemeHandler: NSObject, WKURLSchemeHandler {

	nonisolated static let scheme = "nnwVideoCache"
	static let shared = VideoCacheSchemeHandler()

	private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "VideoCacheSchemeHandler")

	/// Don't accumulate (and cache) items larger than 50 MB to prevent OOM.
	nonisolated private static let maxCacheItemSize = 50 * 1024 * 1024

	/// Tracks URLs currently being downloaded in the background to avoid duplicates.
	nonisolated private static let pendingDownloads = OSAllocatedUnfairLock(initialState: Set<String>())

	/// Downloads video URLs in the background and caches them for future use.
	/// Called for `<video>`/`<source>` URLs that are not yet cached — the video
	/// plays via normal HTTP on this visit, and will be served from cache next time.
	nonisolated static func cacheURLsInBackground(_ urls: [String]) {
		for urlString in urls {
			let shouldStart = pendingDownloads.withLock { pending -> Bool in
				guard !pending.contains(urlString) else { return false }
				_ = pending.insert(urlString)
				return true
			}
			guard shouldStart else { continue }

			if VideoCacheDatabase.shared.hasCachedData(for: urlString) {
				pendingDownloads.withLock { _ = $0.remove(urlString) }
				continue
			}

			guard let url = URL(string: urlString) else {
				pendingDownloads.withLock { _ = $0.remove(urlString) }
				continue
			}

			URLSession.shared.downloadTask(with: url) { tempURL, response, error in
				defer { pendingDownloads.withLock { _ = $0.remove(urlString) } }

				guard let tempURL, error == nil,
					  let httpResponse = response as? HTTPURLResponse,
					  httpResponse.statusCode == 200 else { return }

				// Check file size before reading into memory
				guard let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
					  let fileSize = attrs[.size] as? Int,
					  fileSize <= maxCacheItemSize else { return }

				guard let data = try? Data(contentsOf: tempURL) else { return }

				let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
				VideoCacheDatabase.shared.cacheData(url: urlString, data: data, contentType: contentType)
			}.resume()
		}
	}

	private lazy var session: URLSession = {
		let config = URLSessionConfiguration.ephemeral
		config.timeoutIntervalForRequest = 30
		return URLSession(configuration: config, delegate: self, delegateQueue: nil)
	}()

	/// Maps URLSessionTask.taskIdentifier → StreamContext.
	private let activeStreams = OSAllocatedUnfairLock(initialState: [Int: StreamContext]())

	/// Tracks scheme tasks that have NOT been stopped yet.
	/// Used to guard all calls to WKURLSchemeTask methods.
	/// All WKURLSchemeTask calls MUST happen on the main thread inside
	/// a block that first checks this set — this avoids both the
	/// "calling a stopped task" crash and potential deadlocks from
	/// calling WKWebView APIs under a lock.
	private let activeSchemeTasks = OSAllocatedUnfairLock(initialState: Set<ObjectIdentifier>())

	func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
		guard let requestURL = urlSchemeTask.request.url,
			  let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
			  let originalURLString = components.queryItems?.first(where: { $0.name == "url" })?.value,
			  let originalURL = URL(string: originalURLString) else {
			urlSchemeTask.didFailWithError(URLError(.badURL))
			return
		}

		let schemeTaskID = ObjectIdentifier(urlSchemeTask as AnyObject)
		activeSchemeTasks.withLock { _ = $0.insert(schemeTaskID) }

		// Cache hit — serve from SQLite with Range support
		if let cached = VideoCacheDatabase.shared.cachedData(for: originalURLString) {
			serveCachedData(cached, for: originalURL, urlSchemeTask: urlSchemeTask, schemeTaskID: schemeTaskID, rangeHeader: urlSchemeTask.request.value(forHTTPHeaderField: "Range"))
			return
		}

		// Cache miss — forward to upstream, including Range header if present
		var request = URLRequest(url: originalURL)
		if let rangeHeader = urlSchemeTask.request.value(forHTTPHeaderField: "Range") {
			request.setValue(rangeHeader, forHTTPHeaderField: "Range")
		}

		let context = StreamContext(urlSchemeTask: urlSchemeTask, schemeTaskID: schemeTaskID, originalURL: originalURL, originalURLString: originalURLString)
		let dataTask = session.dataTask(with: request)
		context.sessionTask = dataTask

		activeStreams.withLock { $0[dataTask.taskIdentifier] = context }
		dataTask.resume()
	}

	func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
		let schemeTaskID = ObjectIdentifier(urlSchemeTask as AnyObject)

		// Remove from active set — pending main-thread dispatches will check and skip
		activeSchemeTasks.withLock { _ = $0.remove(schemeTaskID) }

		// Cancel the associated URLSession task and clean up
		activeStreams.withLock { streams in
			for (taskID, context) in streams where context.schemeTaskID == schemeTaskID {
				context.sessionTask?.cancel()
				_ = streams.removeValue(forKey: taskID)
				break
			}
		}
	}
}

// MARK: - Cache Hit Serving

private extension VideoCacheSchemeHandler {

	/// Called synchronously on main thread from `start`.
	/// `stop` cannot interleave during `start`, so no guard needed.
	func serveCachedData(_ cached: (data: Data, contentType: String), for url: URL, urlSchemeTask: WKURLSchemeTask, schemeTaskID: ObjectIdentifier, rangeHeader: String?) {

		let responseData: Data
		var headerFields: [String: String]
		var statusCode = 200

		if let rangeHeader, let range = Self.parseRangeHeader(rangeHeader, totalLength: cached.data.count) {
			responseData = cached.data[range]
			statusCode = 206
			headerFields = [
				"Content-Type": cached.contentType,
				"Content-Length": "\(responseData.count)",
				"Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(cached.data.count)",
				"Accept-Ranges": "bytes",
				"Cache-Control": "max-age=31536000"
			]
		} else {
			responseData = cached.data
			headerFields = [
				"Content-Type": cached.contentType,
				"Content-Length": "\(responseData.count)",
				"Accept-Ranges": "bytes",
				"Cache-Control": "max-age=31536000"
			]
		}

		guard let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headerFields) else {
			return
		}

		urlSchemeTask.didReceive(response)
		urlSchemeTask.didReceive(responseData)
		urlSchemeTask.didFinish()
		activeSchemeTasks.withLock { _ = $0.remove(schemeTaskID) }
	}

	/// Parses a Range header like "bytes=0-", "bytes=100-200", or "bytes=-500".
	nonisolated static func parseRangeHeader(_ header: String, totalLength: Int) -> Range<Int>? {
		guard header.hasPrefix("bytes=") else { return nil }
		let spec = String(header.dropFirst(6))
		let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
		guard parts.count == 2 else { return nil }

		if parts[0].isEmpty {
			// Suffix range: bytes=-N
			guard let suffix = Int(parts[1]) else { return nil }
			let start = max(0, totalLength - suffix)
			return start..<totalLength
		}

		guard let start = Int(parts[0]) else { return nil }
		let end: Int
		if parts[1].isEmpty {
			end = totalLength - 1
		} else {
			guard let parsed = Int(parts[1]) else { return nil }
			end = min(parsed, totalLength - 1)
		}

		guard start <= end, start < totalLength else { return nil }
		return start..<(end + 1)
	}

	/// Returns true if Content-Range covers the entire file (e.g., "bytes 0-999/1000").
	nonisolated static func isFullContentRange(_ header: String) -> Bool {
		guard header.hasPrefix("bytes ") else { return false }
		let body = String(header.dropFirst(6))
		let slashParts = body.split(separator: "/", maxSplits: 1)
		guard slashParts.count == 2, let total = Int(slashParts[1]) else { return false }
		let rangeParts = slashParts[0].split(separator: "-", maxSplits: 1)
		guard rangeParts.count == 2, let start = Int(rangeParts[0]), let end = Int(rangeParts[1]) else { return false }
		return start == 0 && end == total - 1
	}
}

// MARK: - StreamContext

private extension VideoCacheSchemeHandler {

	final class StreamContext: @unchecked Sendable {
		let urlSchemeTask: WKURLSchemeTask
		let schemeTaskID: ObjectIdentifier
		let originalURL: URL
		let originalURLString: String
		var sessionTask: URLSessionTask?
		var accumulatedData = Data()
		var contentType = "application/octet-stream"
		var upstreamStatusCode = 200
		var canCache = false
		var completionError: (any Error)?

		init(urlSchemeTask: WKURLSchemeTask, schemeTaskID: ObjectIdentifier, originalURL: URL, originalURLString: String) {
			self.urlSchemeTask = urlSchemeTask
			self.schemeTaskID = schemeTaskID
			self.originalURL = originalURL
			self.originalURLString = originalURLString
		}
	}
}

// MARK: - URLSessionDataDelegate
//
// IMPORTANT: All WKURLSchemeTask method calls (didReceive, didFinish,
// didFailWithError) MUST be dispatched to the main thread.
// Calling them from URLSession's background delegate queue can deadlock
// with the main thread (which calls stop under the same lock).

extension VideoCacheSchemeHandler: URLSessionDataDelegate {

	nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {

		let context: StreamContext? = activeStreams.withLock { $0[dataTask.taskIdentifier] }

		guard let context else {
			completionHandler(.cancel)
			return
		}

		guard let httpResponse = response as? HTTPURLResponse else {
			completionHandler(.allow)
			return
		}

		context.contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
		context.upstreamStatusCode = httpResponse.statusCode

		// Determine if this response contains the complete file (cacheable).
		// 200 → full file. 206 with Content-Range covering 0..total → also full file.
		if httpResponse.statusCode == 200 {
			context.canCache = true
		} else if httpResponse.statusCode == 206,
				  let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range"),
				  Self.isFullContentRange(contentRange) {
			context.canCache = true
		}

		// Skip caching if Content-Length exceeds the per-item size limit
		if context.canCache,
		   let contentLengthStr = httpResponse.value(forHTTPHeaderField: "Content-Length"),
		   let contentLength = Int(contentLengthStr),
		   contentLength > Self.maxCacheItemSize {
			context.canCache = false
		}

		// Build response headers to forward
		var headerFields = [
			"Content-Type": context.contentType,
			"Accept-Ranges": "bytes",
			"Cache-Control": "max-age=31536000"
		]
		if let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length") {
			headerFields["Content-Length"] = contentLength
		}
		if let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range") {
			headerFields["Content-Range"] = contentRange
		}

		// Use the original URL (not possibly-redirected response.url)
		let forwardResponse = HTTPURLResponse(url: context.originalURL, statusCode: httpResponse.statusCode, httpVersion: nil, headerFields: headerFields)

		if let forwardResponse {
			let schemeTasks = self.activeSchemeTasks
			DispatchQueue.main.async {
				let isActive = schemeTasks.withLock { $0.contains(context.schemeTaskID) }
				guard isActive else { return }
				context.urlSchemeTask.didReceive(forwardResponse)
			}
		}

		completionHandler(.allow)
	}

	nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {

		let context: StreamContext? = activeStreams.withLock { $0[dataTask.taskIdentifier] }

		guard let context else { return }

		// Accumulate data only when the response covers the full file
		if context.canCache {
			context.accumulatedData.append(data)
			// Stop accumulating if we exceed the size limit (e.g. chunked response with no Content-Length)
			if context.accumulatedData.count > Self.maxCacheItemSize {
				context.canCache = false
				context.accumulatedData = Data()
			}
		}

		let schemeTasks = self.activeSchemeTasks
		DispatchQueue.main.async {
			let isActive = schemeTasks.withLock { $0.contains(context.schemeTaskID) }
			guard isActive else { return }
			context.urlSchemeTask.didReceive(data)
		}
	}

	nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {

		let context: StreamContext? = activeStreams.withLock { $0.removeValue(forKey: task.taskIdentifier) }

		guard let context else { return }

		// Store error in context to avoid capturing non-Sendable `any Error` in closure
		context.completionError = error

		let schemeTasks = self.activeSchemeTasks
		DispatchQueue.main.async {
			let shouldFinish = schemeTasks.withLock { tasks -> Bool in
				guard tasks.contains(context.schemeTaskID) else { return false }
				_ = tasks.remove(context.schemeTaskID)
				return true
			}
			guard shouldFinish else { return }

			if let completionError = context.completionError {
				context.urlSchemeTask.didFailWithError(completionError)
			} else {
				context.urlSchemeTask.didFinish()
			}
		}

		// Cache the complete file outside the main-thread dispatch
		if error == nil && context.canCache {
			VideoCacheDatabase.shared.cacheData(
				url: context.originalURLString,
				data: context.accumulatedData,
				contentType: context.contentType
			)
		}
	}
}
