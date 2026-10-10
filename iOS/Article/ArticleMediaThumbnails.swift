import Foundation
import WebKit

@MainActor enum ArticleMediaThumbnails {
	static let contentWorld = WKContentWorld.world(name: "NetNewsWireMediaThumbnails")

	static var userScript: WKUserScript? {
		guard let url = Bundle.main.url(forResource: "media_thumbnails", withExtension: "js"),
			let source = try? String(contentsOf: url, encoding: .utf8) else {
			return nil
		}
		return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: contentWorld)
	}

	static func configure(_ webView: WKWebView, active: Bool) {
		webView.callAsyncJavaScript("""
		window.nnwMediaThumbnails.setActive(active);
		window.nnwMediaThumbnails.configure(enabled, nativeVideo, labels);
		""", arguments: [
			"active": active,
			"enabled": AppDefaults.shared.showArticleMediaThumbnails,
			"nativeVideo": AppDefaults.shared.useNativeVideoPlayer,
			"labels": [
				"media": NSLocalizedString("Article Media", comment: "Article thumbnail strip accessibility label"),
				"image": NSLocalizedString("Enlarge Image", comment: "Image thumbnail accessibility action"),
				"video": NSLocalizedString("Play Video", comment: "Video thumbnail accessibility action")
			]
		], in: nil, in: contentWorld, completionHandler: nil)
	}

	static func setActive(_ active: Bool, in webView: WKWebView) {
		webView.callAsyncJavaScript("window.nnwMediaThumbnails?.setActive(active);", arguments: ["active": active], in: nil, in: contentWorld, completionHandler: nil)
	}
}
