import XCTest
import UniformTypeIdentifiers
@testable import NetNewsWire

final class ArticleMediaFileTests: XCTestCase {
	private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jWZkAAAAASUVORK5CYII=")!

	func testDownloadedImageUsesDetectedTypeRatherThanTemporaryExtension() throws {
		let downloaded = try temporaryFile(png)
		defer { try? FileManager.default.removeItem(at: downloaded) }
		let file = try ArticleMediaFile.image(downloadedURL: downloaded)
		defer { try? FileManager.default.removeItem(at: file.url) }
		XCTAssertEqual(file.typeIdentifier, UTType.png.identifier)
		XCTAssertEqual(file.url.pathExtension, "png")
		XCTAssertEqual(file.byteCount, png.count)
		XCTAssertFalse(FileManager.default.fileExists(atPath: downloaded.path))
		XCTAssertEqual(try Data(contentsOf: file.url), png)
	}

	func testInlineImagePreservesEncodedData() throws {
		let file = try ArticleMediaFile.image(data: png)
		defer { try? FileManager.default.removeItem(at: file.url) }
		XCTAssertEqual(try Data(contentsOf: file.url), png)
	}

	func testInvalidImageDoesNotMoveDownloadedFile() throws {
		let downloaded = try temporaryFile(Data("<html>not an image</html>".utf8))
		defer { try? FileManager.default.removeItem(at: downloaded) }
		XCTAssertThrowsError(try ArticleMediaFile.image(downloadedURL: downloaded))
		XCTAssertTrue(FileManager.default.fileExists(atPath: downloaded.path))
		XCTAssertThrowsError(try ArticleMediaFile.image(data: Data()))
	}

	func testVideoUsesResponseMimeTypeForExtensionlessSource() throws {
		let downloaded = try temporaryFile(Data([1, 2, 3]))
		defer { try? FileManager.default.removeItem(at: downloaded) }
		let file = try ArticleMediaFile.video(downloadedURL: downloaded, sourceURL: URL(string: "https://example.com/media/1")!, mimeType: "video/quicktime")
		defer { try? FileManager.default.removeItem(at: file.url) }
		XCTAssertEqual(file.url.pathExtension, "mov")
		XCTAssertEqual(file.byteCount, 3)
	}

	func testVideoFallsBackToSourceExtensionForGenericMimeType() throws {
		let downloaded = try temporaryFile(Data([1, 2, 3]))
		defer { try? FileManager.default.removeItem(at: downloaded) }
		let file = try ArticleMediaFile.video(downloadedURL: downloaded, sourceURL: URL(string: "https://example.com/video.mov")!, mimeType: "application/octet-stream")
		defer { try? FileManager.default.removeItem(at: file.url) }
		XCTAssertEqual(file.url.pathExtension, "mov")
	}

	func testStreamingPlaylistIsRejectedWithoutMovingFile() throws {
		let downloaded = try temporaryFile(Data("#EXTM3U".utf8))
		defer { try? FileManager.default.removeItem(at: downloaded) }
		XCTAssertThrowsError(try ArticleMediaFile.video(downloadedURL: downloaded, sourceURL: URL(string: "https://example.com/video.m3u8")!, mimeType: nil))
		XCTAssertThrowsError(try ArticleMediaFile.video(downloadedURL: downloaded, sourceURL: URL(string: "https://example.com/media/1")!, mimeType: "application/vnd.apple.mpegurl"))
		XCTAssertTrue(FileManager.default.fileExists(atPath: downloaded.path))
	}

	private func temporaryFile(_ data: Data) throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("tmp")
		try data.write(to: url)
		return url
	}
}
