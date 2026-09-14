//
//  ArticleMediaSaveStage.swift
//  NetNewsWire-iOS
//

import Foundation
import RSCore

/// Records how far a batch media save got, using a file write that survives an abrupt process
/// termination.
///
/// Diagnostics go through the error log, which is written asynchronously, so the last few messages
/// are lost when the process dies. This marker is written synchronously and read back on the next
/// launch, which is what tells us where a save that crashed actually stopped.
@MainActor
enum ArticleMediaSaveStage {

	private static let fileName = "MediaSaveStage.txt"

	private static var fileURL: URL {
		AppConfig.dataFolder.appendingPathComponent(fileName)
	}

	static func begin(type: String, requestedCount: Int) {
		write("\(type):started:\(requestedCount)")
	}

	static func update(_ stage: String) {
		write(stage)
	}

	static func finish() {
		try? FileManager.default.removeItem(at: fileURL)
	}

	/// The stage left behind by a save that never finished, if there is one.
	static func abandonedStage() -> String? {
		guard let data = try? Data(contentsOf: fileURL),
			let text = String(data: data, encoding: .utf8),
			!text.isEmpty else {
			return nil
		}
		return text
	}
}

private extension ArticleMediaSaveStage {

	static func write(_ stage: String) {
		guard let data = stage.data(using: .utf8) else {
			return
		}
		try? data.write(to: fileURL, options: .atomic)
	}
}
