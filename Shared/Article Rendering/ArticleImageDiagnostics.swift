//
//  ArticleImageDiagnostics.swift
//  NetNewsWire
//
//  Created by qsoyq on 9/19/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation

/// Pure helpers for article image diagnostics. The article web view logs through these so the
/// URL list, ignore rules, and message wording cannot drift between render-time and load-time.
enum ArticleImageDiagnostics {

	static let maxLoggedImageSources = 30

	struct ImageLoadEvent: Equatable, Sendable {
		let status: String
		let source: String
		let width: Int
		let height: Int
		let complete: Bool
		let documentURL: String
		let baseURI: String

		init(status: String, source: String, width: Int, height: Int, complete: Bool, documentURL: String = "", baseURI: String = "") {
			self.status = status
			self.source = source
			self.width = width
			self.height = height
			self.complete = complete
			self.documentURL = documentURL
			self.baseURI = baseURI
		}

		var isFailure: Bool {
			status == "error" || (complete && width <= 0 && !source.isEmpty)
		}
	}

	static func imageSources(inHTML html: String) -> [String] {
		let pattern = "<img\\b[^>]*?\\bsrc\\s*=\\s*[\"']([^\"']+)[\"']"
		guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
			return []
		}

		let nsHTML = html as NSString
		let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length))
		var sources: [String] = []
		var seen = Set<String>()

		for match in matches {
			guard match.numberOfRanges == 2 else { continue }
			let raw = nsHTML.substring(with: match.range(at: 1))
				.replacingOccurrences(of: "&amp;", with: "&")
			let source = originalSource(from: raw)
			guard isDiagnosticImageSource(source), !seen.contains(source) else { continue }
			seen.insert(source)
			sources.append(source)
		}

		return sources
	}

	static func isDiagnosticImageSource(_ source: String) -> Bool {
		let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			return false
		}
		let lowercased = trimmed.lowercased()
		if lowercased.hasPrefix("data:") || lowercased.hasPrefix("blob:") {
			return false
		}
		if lowercased.hasPrefix("nnwimageicon:") {
			return false
		}
		return true
	}

	static func originalSource(from source: String) -> String {
		guard let url = URL(string: source),
			  url.scheme?.caseInsensitiveCompare(VideoCacheSchemeHandler.scheme) == .orderedSame else {
			return source
		}
		return URLComponents(url: url, resolvingAgainstBaseURL: false)?
			.queryItems?
			.first(where: { $0.name == "url" })?
			.value ?? source
	}

	static func imageLoadEvent(from body: Any) -> ImageLoadEvent? {
		if let event = body as? ImageLoadEvent {
			return event
		}
		guard let dictionary = body as? [String: Any] else {
			return nil
		}
		let status = dictionary["status"] as? String ?? ""
		let source = originalSource(from: dictionary["src"] as? String ?? "")
		guard isDiagnosticImageSource(source) else {
			return nil
		}
		let width = intValue(dictionary["width"])
		let height = intValue(dictionary["height"])
		let complete = (dictionary["complete"] as? Bool) ?? false
		let documentURL = dictionary["documentURL"] as? String ?? ""
		let baseURI = dictionary["baseURI"] as? String ?? ""
		return ImageLoadEvent(status: status, source: source, width: width, height: height, complete: complete, documentURL: documentURL, baseURI: baseURI)
	}

	static func renderMessage(articleID: String, link: String?, loadBaseURL: String, htmlBaseURL: String, imageSources: [String]) -> String {
		let displayedSources = Array(imageSources.prefix(maxLoggedImageSources))
		let omitted = imageSources.count - displayedSources.count
		var parts = [
			"articleID=\(articleID)",
			"link=\(link ?? "(none)")",
			"loadBaseURL=\(loadBaseURL)",
			"htmlBaseURL=\(htmlBaseURL.isEmpty ? "(none)" : htmlBaseURL)",
			"images=\(imageSources.count)"
		]
		if !displayedSources.isEmpty {
			parts.append("src=\(displayedSources.joined(separator: " | "))")
		}
		if omitted > 0 {
			parts.append("omitted=\(omitted)")
		}
		return parts.joined(separator: "; ")
	}

	static func imageLoadMessage(_ event: ImageLoadEvent) -> String {
		var parts = [
			event.status,
			event.source,
			"\(event.width)x\(event.height)",
			"complete=\(event.complete)"
		]
		if !event.documentURL.isEmpty {
			parts.append("documentURL=\(event.documentURL)")
		}
		if !event.baseURI.isEmpty {
			parts.append("baseURI=\(event.baseURI)")
		}
		return parts.joined(separator: " ")
	}

	static func loadSummaryMessage(articleID: String, link: String?, loadBaseURL: String, htmlBaseURL: String, documentURL: String, expectedCount: Int, events: [ImageLoadEvent]) -> String {
		let failures = events.filter(\.isFailure)
		let successes = events.filter { !$0.isFailure }
		return [
			"articleID=\(articleID)",
			"link=\(link ?? "(none)")",
			"loadBaseURL=\(loadBaseURL)",
			"htmlBaseURL=\(htmlBaseURL.isEmpty ? "(none)" : htmlBaseURL)",
			"documentURL=\(documentURL.isEmpty ? "(none)" : documentURL)",
			"expected=\(expectedCount)",
			"loaded=\(successes.count)",
			"failed=\(failures.count)",
			"failedSrc=\(failures.map(\.source).prefix(maxLoggedImageSources).joined(separator: " | "))"
		].joined(separator: "; ")
	}

	static func shouldLogLoadSummary(expectedCount: Int, events: [ImageLoadEvent]) -> Bool {
		guard expectedCount > 0 else {
			return false
		}
		let failures = events.filter(\.isFailure)
		let successes = events.filter { !$0.isFailure }
		return !failures.isEmpty || successes.isEmpty
	}

	private static func intValue(_ value: Any?) -> Int {
		if let intValue = value as? Int {
			return intValue
		}
		if let number = value as? NSNumber {
			return number.intValue
		}
		if let doubleValue = value as? Double {
			return Int(doubleValue)
		}
		return 0
	}
}
