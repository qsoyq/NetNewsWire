import Foundation
import XCTest
import RSCore
import RSWeb
@testable import Images

final class Flag: @unchecked Sendable { var value: Bool; init(_ value: Bool) { self.value = value } }

@MainActor final class ImageDownloaderCacheTests: XCTestCase {
	private let url = "https://example.com/icon.png"
	private let imageA = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lE4E1QAAAABJRU5ErkJggg==")!
	private let imageB = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
	private func folder() throws -> URL { let f = FileManager.default.temporaryDirectory.appendingPathComponent("ImageProbe-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true); return f }
	private func response(_ data: Data) -> DownloadResponse { DownloadResponse(data: data, response: HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: nil, headerFields: nil), returnedFromCache: false) }

	func testExpiredDiskImageRevalidatesWithSameURL() async throws {
		let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
		let cache = BinaryDiskCache(folder: folder.path)
		try cache.setData(imageA, forKey: url.md5String)
		try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ImageCacheSettings.lifetime - 1)], ofItemAtPath: folder.appendingPathComponent(url.md5String).path)
		nonisolated(unsafe) var requests = 0
		let downloader = ImageDownloader(diskCache: cache, now: { Date() }, download: { _ in requests += 1; return self.response(self.imageB) })
		_ = downloader.image(for: url)
		try await Task.sleep(for: .milliseconds(300))
		XCTAssertEqual(requests, 1); XCTAssertTrue(downloader.isFresh(url)); XCTAssertNotEqual(downloader.image(for: url), imageA)
	}
	func testFailedRefreshKeepsOldImageAndRetriesLater() async throws {
		let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
		let cache = BinaryDiskCache(folder: folder.path)
		try cache.setData(imageA, forKey: url.md5String)
		nonisolated(unsafe) var current = Date()
		try FileManager.default.setAttributes([.modificationDate: current.addingTimeInterval(-ImageCacheSettings.lifetime - 1)], ofItemAtPath: folder.appendingPathComponent(url.md5String).path)
		let shouldFail = Flag(true); nonisolated(unsafe) var requests = 0
		let downloader = ImageDownloader(diskCache: cache, now: { current }, download: { _ in requests += 1; if shouldFail.value { throw URLError(.notConnectedToInternet) }; return self.response(self.imageB) })
		_ = downloader.image(for: url); try await Task.sleep(for: .milliseconds(300))
		XCTAssertNotNil(downloader.image(for: url)); XCTAssertEqual(requests, 1)
		shouldFail.value = false; current = current.addingTimeInterval(31 * 60); _ = downloader.image(for: url); try await Task.sleep(for: .milliseconds(300))
		XCTAssertEqual(requests, 2)
	}
	func testClearCacheRejectsStaleInFlightDownload() async throws {
		let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
		let cache = BinaryDiskCache(folder: folder.path); nonisolated(unsafe) var requests = 0
		let downloader = ImageDownloader(diskCache: cache, now: { Date() }, download: { _ in requests += 1; try await Task.sleep(for: .milliseconds(150)); return self.response(self.imageA) })
		_ = downloader.image(for: url); try await Task.sleep(for: .milliseconds(20)); try await downloader.clearCache(); try await Task.sleep(for: .milliseconds(350))
		XCTAssertEqual(requests, 1); XCTAssertFalse(downloader.isFresh(url)); XCTAssertNil(try cache.dataAndModificationDate(forKey: url.md5String))
	}
}
