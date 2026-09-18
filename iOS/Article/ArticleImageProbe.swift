//
//  ArticleImageProbe.swift
//  NetNewsWire-iOS
//
//  Created by qsoyq on 9/19/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import RSWeb

/// Native GET probe for article images that failed in WKWebView.
///
/// rssapi media URLs often 302 with an empty body and no Content-Type, and HEAD
/// is 405 JSON. A browser follows that; this probe records the actual chain.
enum ArticleImageProbe {

	private static let session: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configuration.timeoutIntervalForRequest = 15
		configuration.httpMaximumConnectionsPerHost = 4
		configuration.httpShouldSetCookies = false
		configuration.urlCache = nil
		if let userAgentHeaders = UserAgent.headers() {
			configuration.httpAdditionalHeaders = userAgentHeaders
		}
		return URLSession(configuration: configuration)
	}()

	static func describe(_ urlString: String) async -> String {
		guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
			return "skip \(urlString)"
		}

		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		request.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

		do {
			let (data, response) = try await session.data(for: request)
			let http = response as? HTTPURLResponse
			let status = http?.statusCode ?? -1
			let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? "(none)"
			let finalURL = http?.url?.absoluteString ?? urlString
			let prefix = data.prefix(16).map { String(format: "%02x", $0) }.joined()
			let kind: String
			if data.starts(with: [0xFF, 0xD8, 0xFF]) {
				kind = "jpeg"
			} else if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
				kind = "png"
			} else if data.starts(with: [0x47, 0x49, 0x46]) {
				kind = "gif"
			} else if data.prefix(16).contains(where: { $0 == 0x3C }) {
				kind = "html-or-xml"
			} else {
				kind = "unknown"
			}
			return "status=\(status) contentType=\(contentType) bytes=\(data.count) kind=\(kind) final=\(finalURL) prefix=\(prefix) original=\(urlString)"
		} catch {
			return "probe-error \(error.localizedDescription) original=\(urlString)"
		}
	}
}
