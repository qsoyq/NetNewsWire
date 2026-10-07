import Foundation
@preconcurrency import WebKit

@MainActor enum ArticleDisclosureController {
	static let contentWorld = WKContentWorld.world(name: "NetNewsWireArticleDisclosure")

	static var userScript: WKUserScript? {
		guard let url = Bundle.main.url(forResource: "article_disclosure", withExtension: "js"),
			let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
		return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: contentWorld)
	}

	static func configure(_ webView: WKWebView, enabled: Bool) async throws {
		_ = try await webView.callAsyncJavaScript("window.nnwArticleDisclosure.configure(enabled);", arguments: ["enabled": enabled], in: nil, contentWorld: contentWorld)
	}
}
