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

	static func logRender(articleID: String, link: String?, loadBaseURL: String, htmlBaseURL: String, imageSources: [String]) {
		let message = ArticleImageDiagnostics.renderMessage(
			articleID: articleID,
			link: link,
			loadBaseURL: loadBaseURL,
			htmlBaseURL: htmlBaseURL,
			imageSources: imageSources
		)
		log(.info, operation: "Render", message: message)
	}

	static func logImageLoad(_ event: ArticleImageDiagnostics.ImageLoadEvent) {
		let level: ErrorLogLevel = event.isFailure ? .warning : .debug
		// Failures keep the full URL; that is the whole point of this diagnostic.
		let source = event.isFailure ? event.source : urlDescription(event.source, level: level)
		let described = ArticleImageDiagnostics.ImageLoadEvent(
			status: event.status,
			source: source,
			width: event.width,
			height: event.height,
			complete: event.complete,
			documentURL: event.documentURL,
			baseURI: event.baseURI
		)
		log(level, operation: "Image load", message: ArticleImageDiagnostics.imageLoadMessage(described))
	}

	static func logLoadSummary(articleID: String, link: String?, loadBaseURL: String, htmlBaseURL: String, documentURL: String, expectedCount: Int, events: [ArticleImageDiagnostics.ImageLoadEvent]) {
		guard ArticleImageDiagnostics.shouldLogLoadSummary(expectedCount: expectedCount, events: events) else {
			return
		}
		let message = ArticleImageDiagnostics.loadSummaryMessage(
			articleID: articleID,
			link: link,
			loadBaseURL: loadBaseURL,
			htmlBaseURL: htmlBaseURL,
			documentURL: documentURL,
			expectedCount: expectedCount,
			events: events
		)
		log(.warning, operation: "Image summary", message: message)
	}
}
