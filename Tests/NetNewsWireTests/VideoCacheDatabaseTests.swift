import XCTest
import Foundation
@testable import NetNewsWire

final class VideoCacheDatabaseTests: XCTestCase {
	func testCachedBytesSurviveTheSwiftBindingBufferLifetime() throws {
		let url = "https://example.invalid/cache-\(UUID().uuidString)?name=视频"
		for count in [1, 3, 14, 15, 256, 4096] {
			let expected = Data((0..<count).map { UInt8($0 % 251) })
			VideoCacheDatabase.shared.cacheData(url: url, data: expected, contentType: "image/jpeg")
			XCTAssertTrue(VideoCacheDatabase.shared.hasCachedData(for: url))
			let cached = try XCTUnwrap(VideoCacheDatabase.shared.cachedData(for: url))
			XCTAssertEqual(Array(cached.data), Array(expected), "Payload size: \(count)")
			XCTAssertEqual(cached.contentType, "image/jpeg")
		}
	}
}
