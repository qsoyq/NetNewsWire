import Foundation
import RSParser

enum VideoPreviewSources {
	static func urls(in html: String, baseURL: URL?) -> [URL] {
		let collector = Collector(baseURL: baseURL)
		HTMLScanner(delegate: collector).parse(Array(html.utf8))
		return collector.urls
	}

	static func originalURL(_ source: String, baseURL: URL?) -> URL? {
		guard var url = URL(string: source, relativeTo: baseURL)?.absoluteURL else { return nil }
		if url.scheme?.lowercased() == VideoCacheSchemeHandler.scheme.lowercased(),
			let original = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
			let originalURL = URL(string: original) { url = originalURL }
		guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
		return url
	}

	private final class Collector: HTMLScannerDelegate {
		var urls: [URL] = []
		private var baseURL: URL?
		private var eligible = false
		private var source: String?
		private var seen = Set<URL>()

		init(baseURL: URL?) { self.baseURL = baseURL }

		func htmlScanner(_ scanner: HTMLScanner, didStartTag name: ArraySlice<UInt8>, attributes: HTMLAttributes, selfClosing: Bool) {
			switch String(decoding: name, as: UTF8.self).lowercased() {
			case "base":
				if let href = attributes["href"], let url = URL(string: href, relativeTo: baseURL) { baseURL = url.absoluteURL }
			case "video":
				finishVideo()
				eligible = (attributes["poster"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
					&& !(attributes["class"] ?? "").split(whereSeparator: { $0.isWhitespace }).contains("nnwAnimatedGIF")
				source = attributes["src"].flatMap { $0.isEmpty ? nil : $0 }
				if selfClosing { finishVideo() }
			case "source":
				if eligible, source == nil, let value = attributes["src"], !value.isEmpty { source = value }
			default: break
			}
		}

		func htmlScanner(_ scanner: HTMLScanner, didEndTag name: ArraySlice<UInt8>) {
			if String(decoding: name, as: UTF8.self).lowercased() == "video" { finishVideo() }
		}
		func htmlScannerDidEnd(_ scanner: HTMLScanner) { finishVideo() }

		private func finishVideo() {
			if eligible, let source, let url = originalURL(source, baseURL: baseURL), seen.insert(url).inserted { urls.append(url) }
			eligible = false
			source = nil
		}
	}
}
