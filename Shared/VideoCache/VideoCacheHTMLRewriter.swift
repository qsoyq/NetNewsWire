//
//  VideoCacheHTMLRewriter.swift
//  NetNewsWire
//
//  Created by NetNewsWire on 2026/04/13.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation

enum VideoCacheHTMLRewriter {

	/// Rewrites media src URLs to use the video cache scheme.
	///
	/// - `<video>` / `<source>`: only rewritten when the URL is already cached.
	///   Media players don't handle proxied custom-scheme URLs well (latency causes
	///   stalls). Uncached URLs are left as-is so they load via normal HTTP; they are
	///   returned in `uncachedVideoURLs` for background downloading.
	/// - `<iframe>`: never rewritten — iframes load full web pages (YouTube, etc.)
	///   that require their original origin for JS, CORS, and API requests.
	static func rewriteForCaching(_ html: String) -> (html: String, uncachedVideoURLs: [String]) {
		var result = html
		var uncachedVideoURLs: [String] = []

		// <video>/<source>: only rewrite when cached
		result = rewriteTag(in: result, tag: "video", onlyIfCached: true, uncachedURLs: &uncachedVideoURLs)
		result = rewriteTag(in: result, tag: "source", onlyIfCached: true, uncachedURLs: &uncachedVideoURLs)

		return (result, uncachedVideoURLs)
	}
}

private extension VideoCacheHTMLRewriter {

	static func rewriteTag(in html: String, tag: String, onlyIfCached: Bool, uncachedURLs: inout [String]) -> String {
		let pattern = "(<\(tag)\\b[^>]*?\\bsrc\\s*=\\s*\")([^\"]+)(\")"

		guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
			return html
		}

		let nsHTML = html as NSString
		let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length))

		var mutableHTML = html
		for match in matches.reversed() {
			guard match.numberOfRanges == 4 else { continue }

			let urlRange = match.range(at: 2)
			guard let swiftRange = Range(urlRange, in: mutableHTML) else { continue }

			let rawURL = String(mutableHTML[swiftRange])

			// Decode common HTML entities in attribute values
			let originalURL = rawURL.replacingOccurrences(of: "&amp;", with: "&")

			// Skip data: URLs, blob: URLs, and already-rewritten URLs
			if originalURL.hasPrefix("data:") ||
				originalURL.hasPrefix("blob:") ||
				originalURL.hasPrefix("\(VideoCacheSchemeHandler.scheme):") {
				continue
			}

			// Skip non-HTTP URLs
			guard originalURL.hasPrefix("http://") || originalURL.hasPrefix("https://") else {
				continue
			}

			// In onlyIfCached mode, skip rewriting and queue for background download
			if onlyIfCached && !VideoCacheDatabase.shared.hasCachedData(for: originalURL) {
				uncachedURLs.append(originalURL)
				continue
			}

			// Build cache URL using URLComponents for correct query encoding.
			var cacheComponents = URLComponents()
			cacheComponents.scheme = VideoCacheSchemeHandler.scheme
			cacheComponents.host = "cache"
			cacheComponents.queryItems = [URLQueryItem(name: "url", value: originalURL)]

			guard let cacheURL = cacheComponents.string else { continue }

			mutableHTML = mutableHTML.replacingCharacters(in: swiftRange, with: cacheURL)
		}

		return mutableHTML
	}
}
