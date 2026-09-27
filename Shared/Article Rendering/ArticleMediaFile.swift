import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ArticleMediaFile: Sendable {
	enum PreparationError: Error {
		case undecodableImage
		case unsupportedVideo
	}

	let url: URL
	let byteCount: Int
	let typeIdentifier: String

	static func image(data: Data) throws -> ArticleMediaFile {
		guard !data.isEmpty,
			let source = CGImageSourceCreateWithData(data as CFData, nil) else {
			throw PreparationError.undecodableImage
		}
		let type = try imageType(source)
		let url = temporaryURL(type: type)
		try data.write(to: url, options: .atomic)
		return ArticleMediaFile(url: url, byteCount: data.count, typeIdentifier: type.identifier)
	}

	static func image(downloadedURL: URL) throws -> ArticleMediaFile {
		guard let source = CGImageSourceCreateWithURL(downloadedURL as CFURL, nil) else {
			throw PreparationError.undecodableImage
		}
		return try move(downloadedURL, type: imageType(source))
	}

	static func video(downloadedURL: URL, sourceURL: URL, mimeType: String?) throws -> ArticleMediaFile {
		guard mimeType?.lowercased().contains("mpegurl") != true,
			sourceURL.pathExtension.lowercased() != "m3u8" else {
			throw PreparationError.unsupportedVideo
		}
		let mimeType = mimeType.flatMap { UTType(mimeType: $0) }
		let extensionType = UTType(filenameExtension: sourceURL.pathExtension)
		let type = [mimeType, extensionType].compactMap { $0 }.first { $0.conforms(to: .movie) } ?? .mpeg4Movie
		return try move(downloadedURL, type: type)
	}

	private static func imageType(_ source: CGImageSource) throws -> UTType {
		// Reject unsupported/empty data before handing a file to PhotoKit's Objective-C API.
		guard CGImageSourceGetCount(source) > 0,
			let identifier = CGImageSourceGetType(source),
			let type = UTType(identifier as String), type.conforms(to: .image) else {
			throw PreparationError.undecodableImage
		}
		return type
	}

	private static func move(_ sourceURL: URL, type: UTType) throws -> ArticleMediaFile {
		let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
		let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
		let destination = temporaryURL(type: type)
		try FileManager.default.moveItem(at: sourceURL, to: destination)
		return ArticleMediaFile(url: destination, byteCount: byteCount, typeIdentifier: type.identifier)
	}

	private static func temporaryURL(type: UTType) -> URL {
		FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
			.appendingPathExtension(type.preferredFilenameExtension ?? "dat")
	}
}
