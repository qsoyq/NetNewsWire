//
//  ArticleMediaLog.swift
//  NetNewsWire-iOS
//

import Foundation
import ErrorLog

/// The one place batch media saving writes diagnostics, so the log level filter and the URL privacy
/// rules cannot drift between the view controller that starts a save and the saver that performs it.
enum ArticleMediaLog {

	static let sourceName = "Article Media"
	static let sourceID = 100

	/// Logs `message` unless the configured level filters it out.
	///
	/// A full media URL is only ever written at the debug level. Everything at warning and above
	/// keeps the scheme and host, which is enough to tell downloads apart without putting complete
	/// article image links in a log the user may share.
	static func log(_ level: ErrorLogLevel, operation: String, message: String) {
		guard level.rawValue >= AppDefaults.shared.errorLogLevel.rawValue else {
			return
		}
		let userInfo = ErrorLogUserInfoKey.userInfo(sourceName: sourceName, sourceID: sourceID, operation: operation, errorMessage: message, level: level)
		NotificationCenter.default.post(name: .appDidEncounterError, object: nil, userInfo: userInfo)
	}

	static func urlDescription(_ source: String, level: ErrorLogLevel) -> String {
		guard level != .debug else {
			return source
		}
		if source.lowercased().hasPrefix("data:") {
			return "data:"
		}
		guard let url = URL(string: source), let host = url.host else {
			return "(unparsable source)"
		}
		return "\(url.scheme ?? "?")://\(host)"
	}
}
