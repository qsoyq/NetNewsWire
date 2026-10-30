import Foundation
import WebKit
import UIKit
import RSWeb

@MainActor enum ArticleMediaThumbnails {
	static let contentWorld = WKContentWorld.world(name: "NetNewsWireMediaThumbnails")

	static var userScript: WKUserScript? {
		guard let url = Bundle.main.url(forResource: "media_thumbnails", withExtension: "js"),
			let source = try? String(contentsOf: url, encoding: .utf8) else {
			return nil
		}
		return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: contentWorld)
	}

	/// The stylesheet is parsed before the body, so media never paints at its original size.
	/// The isolated script consumes the initial configuration at document end.
	static func prepareHTML(_ html: String) -> String {
		guard AppDefaults.shared.hideArticleBodyMedia,
			let head = html.range(of: "<head>", options: .caseInsensitive),
			let data = try? JSONSerialization.data(withJSONObject: configuration),
			let json = String(data: data, encoding: .utf8) else {
			return html
		}
		let attribute = json.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "\"", with: "&quot;")
			.replacingOccurrences(of: "<", with: "&lt;")
		let style = """
		<style id="nnw-media-initial-visibility" data-configuration="\(attribute)">
		:is(#bodyContainer,.articleBody,.article-body) :is(img,video) { display:none!important; }
		</style>
		"""
		var result = html
		result.insert(contentsOf: style, at: head.upperBound)
		return result
	}

	private static var configuration: [String: Any] {
		[
			"enabled": AppDefaults.shared.showArticleMediaThumbnails,
			"hideBodyMedia": AppDefaults.shared.hideArticleBodyMedia,
			"nativeVideo": AppDefaults.shared.useNativeVideoPlayer,
			"labels": [
				"link": NSLocalizedString("Open Media Link", comment: "Link replacing a hidden linked image"),
				"media": NSLocalizedString("Article Media", comment: "Article thumbnail strip accessibility label"),
				"image": NSLocalizedString("Enlarge Image", comment: "Image thumbnail accessibility action"),
				"video": NSLocalizedString("Play Video", comment: "Video thumbnail accessibility action")
			]
		]
	}

	static func configure(_ webView: WKWebView, active: Bool) {
		webView.callAsyncJavaScript("""
		window.nnwMediaThumbnails.setActive(active);
		window.nnwMediaThumbnails.configure(enabled, nativeVideo, labels, hideBodyMedia);
		""", arguments: configuration.merging(["active": active]) { _, value in value }, in: nil, in: contentWorld, completionHandler: nil)
	}

	static func setActive(_ active: Bool, in webView: WKWebView) {
		webView.callAsyncJavaScript("window.nnwMediaThumbnails?.setActive(active);", arguments: ["active": active], in: nil, in: contentWorld, completionHandler: nil)
	}

	/// Downloads the image natively and returns a small JPEG data URL. Native downloading does not
	/// share WKWebView's request state, so it works when the web view could not fetch the image.
	static func fallbackDataURL(for urlString: String) async -> String? {
		guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
			return nil
		}
		guard let data = try? await Downloader.shared.download(url, userAgentStyle: .browser).data, !data.isEmpty else {
			return nil
		}
		guard let image = UIImage(data: data) else {
			return nil
		}
		let scale = max(1, min(3, UIScreen.main.scale))
		let target = CGSize(width: 112 * scale, height: 88 * scale)
		let thumbnail = await image.byPreparingThumbnail(ofSize: aspectFillSize(image.size, in: target)) ?? image
		guard let jpeg = thumbnail.jpegData(compressionQuality: 0.8) else {
			return nil
		}
		return "data:image/jpeg;base64," + jpeg.base64EncodedString()
	}

	private static func aspectFillSize(_ size: CGSize, in target: CGSize) -> CGSize {
		guard size.width > 0, size.height > 0 else {
			return target
		}
		let ratio = max(target.width / size.width, target.height / size.height)
		guard ratio < 1 else {
			return size
		}
		return CGSize(width: size.width * ratio, height: size.height * ratio)
	}

	static func deliverFallback(_ dataURL: String?, for url: String, in webView: WKWebView) {
		webView.callAsyncJavaScript("window.nnwMediaThumbnails?.setFallback(url, dataURL);", arguments: ["url": url, "dataURL": dataURL ?? NSNull()], in: nil, in: contentWorld, completionHandler: nil)
	}

	static func retryFailed(in webView: WKWebView) {
		webView.callAsyncJavaScript("window.nnwMediaThumbnails?.retryFailed();", arguments: [:], in: nil, in: contentWorld, completionHandler: nil)
	}
}
