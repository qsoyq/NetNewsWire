import Foundation
import CryptoKit

actor VideoPreviewCache {
	static let shared = VideoPreviewCache()
	private let directory: URL
	private let maximumSize: Int
	private var generation = 0

	init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("VideoPreviews", isDirectory: true), maximumSize: Int = 50 * 1024 * 1024) {
		self.directory = directory
		self.maximumSize = maximumSize
	}

	func epoch() -> Int { generation }

	func data(for url: URL) -> Data? {
		let file = path(for: url)
		guard let data = try? Data(contentsOf: file) else { return nil }
		try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
		return data
	}

	func store(_ data: Data, for url: URL, epoch: Int) {
		guard epoch == generation, data.count <= maximumSize else { return }
		do {
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			try data.write(to: path(for: url), options: .atomic)
			let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
			let entries = files.compactMap { file -> (URL, Int, Date)? in
				guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
				return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
			}.sorted { $0.2 < $1.2 }
			var size = entries.reduce(0) { $0 + $1.1 }
			for entry in entries where size > maximumSize {
				try FileManager.default.removeItem(at: entry.0)
				size -= entry.1
			}
		} catch {
			// A preview remains usable even when its disposable disk cache is unavailable.
		}
	}

	func clear() {
		generation += 1
		try? FileManager.default.removeItem(at: directory)
	}

	private func path(for url: URL) -> URL {
		let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
		return directory.appendingPathComponent(hash).appendingPathExtension("jpg")
	}
}
