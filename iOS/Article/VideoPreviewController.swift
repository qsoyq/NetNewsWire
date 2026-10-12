import Foundation
@preconcurrency import WebKit

@MainActor final class VideoPreviewController: NSObject {
	static let contentWorld = WKContentWorld.world(name: "NetNewsWireVideoPreview")
	static var userScript: WKUserScript? {
		guard let url = Bundle.main.url(forResource: "video_preview", withExtension: "js"),
			let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
		return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: contentWorld)
	}
	struct Source: Decodable { let id: String; let url: String }
	private weak var webView: WKWebView?
	private var documentID = UUID().uuidString
	private var setupTask: Task<Void, Never>?
	private var requests: [Task<Void, Never>] = []
	private var isActive = false
	private var attempted = Set<String>()
	private var lastEnabled = AppDefaults.shared.loadVideoFirstFramePreview
	private var lastPreload = AppDefaults.shared.preloadVideoContent
	private let service: VideoPreviewService

	init(service: VideoPreviewService = .shared) {
		self.service = service
		super.init()
		NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .videoPreviewSettingsDidChange, object: nil)
	}
	deinit {
		setupTask?.cancel()
		for request in requests { request.cancel() }
		NotificationCenter.default.removeObserver(self)
	}

	func documentWillChange() {
		cancelRequests()
		documentID = UUID().uuidString
		attempted.removeAll()
		webView = nil
	}

	func documentDidLoad(_ webView: WKWebView) {
		documentWillChange()
		self.webView = webView
		configure()
	}

	func setActive(_ active: Bool) {
		isActive = active
		if active {
			configure()
		} else {
			cancelRequests()
			releasePreload()
		}
	}

	private func releasePreload() {
		guard let webView else { return }
		let id = documentID
		let enabled = AppDefaults.shared.loadVideoFirstFramePreview
		Task { [weak webView] in
			guard let webView else { return }
			_ = try? await webView.callAsyncJavaScript("window.nnwVideoPreview.configure(id, enabled, preload);", arguments: ["id": id, "enabled": enabled, "preload": false], in: nil, contentWorld: Self.contentWorld)
		}
	}

	private func cancelRequests() {
		setupTask?.cancel()
		setupTask = nil
		for request in requests { request.cancel() }
		requests.removeAll()
	}

	private func configure() {
		guard let webView else { return }
		cancelRequests()
		let id = documentID
		let enabled = AppDefaults.shared.loadVideoFirstFramePreview
		let preload = AppDefaults.shared.preloadVideoContent && isActive
		setupTask = Task { [weak self, weak webView] in
			guard let self, let webView else { return }
			do {
				_ = try await webView.callAsyncJavaScript("window.nnwVideoPreview.configure(id, enabled, preload);", arguments: ["id": id, "enabled": enabled, "preload": preload], in: nil, contentWorld: Self.contentWorld)
				guard !Task.isCancelled, self.documentID == id, enabled, self.isActive else { return }
				let sources = try await Self.collect(webView, documentID: id)
				guard !Task.isCancelled, self.documentID == id else { return }
				for source in sources where !self.attempted.contains(source.id) {
					guard let url = URL(string: source.url) else { continue }
					let service = self.service
					self.requests.append(Task { [weak self, weak webView] in
						do {
							let data = try await service.preview(for: url)
							guard !Task.isCancelled, let self, let webView, self.documentID == id,
								self.isActive, AppDefaults.shared.loadVideoFirstFramePreview else { return }
							self.attempted.insert(source.id)
							_ = try await Self.apply(data, source: source, documentID: id, in: webView)
						} catch let error as VideoPreviewService.Unavailable {
							guard !Task.isCancelled, let self, let webView, self.documentID == id, self.isActive,
								AppDefaults.shared.loadVideoFirstFramePreview else { return }
							self.attempted.insert(source.id)
							_ = try? await Self.markUnavailable(source: source, documentID: id, in: webView)
							ArticleMediaLog.log(.debug, operation: "Video preview", message: "source=\(ArticleMediaLog.urlDescription(source.url, level: .info)) outcome=unavailable status=\(error.statusCode)")
						} catch {
							if !Task.isCancelled {
								if let self, self.documentID == id { self.attempted.insert(source.id) }
								ArticleMediaLog.log(.debug, operation: "Video preview", message: "source=\(ArticleMediaLog.urlDescription(source.url, level: .info)) outcome=failed")
							}
						}
					})
				}
			} catch { /* A replaced document is configured on its next successful load. */ }
		}
	}

	static func collect(_ webView: WKWebView, documentID: String) async throws -> [Source] {
		let result = try await webView.callAsyncJavaScript("return window.nnwVideoPreview.collect(id);", arguments: ["id": documentID], in: nil, contentWorld: contentWorld)
		guard let json = result as? String else { return [] }
		return try JSONDecoder().decode([Source].self, from: Data(json.utf8))
	}

	@discardableResult static func apply(_ data: Data, source: Source, documentID: String, in webView: WKWebView) async throws -> Bool {
		let result = try await webView.callAsyncJavaScript("return window.nnwVideoPreview.apply(documentID, id, url, poster);", arguments: ["documentID": documentID, "id": source.id, "url": source.url, "poster": "data:image/jpeg;base64," + data.base64EncodedString()], in: nil, contentWorld: contentWorld)
		return result as? Bool ?? false
	}

	@discardableResult static func markUnavailable(source: Source, documentID: String, in webView: WKWebView) async throws -> Bool {
		let label = NSLocalizedString("Video cannot be played", comment: "Accessibility label for an unavailable video preview")
		let result = try await webView.callAsyncJavaScript("return window.nnwVideoPreview.markUnavailable(documentID, id, url, label);", arguments: ["documentID": documentID, "id": source.id, "url": source.url, "label": label], in: nil, contentWorld: contentWorld)
		return result as? Bool ?? false
	}

	@objc private func settingsChanged() {
		let enabled = AppDefaults.shared.loadVideoFirstFramePreview
		let preload = AppDefaults.shared.preloadVideoContent
		guard lastEnabled != enabled || lastPreload != preload else { return }
		let previewChanged = lastEnabled != enabled
		lastEnabled = enabled
		lastPreload = preload
		if previewChanged {
			documentID = UUID().uuidString
			attempted.removeAll()
		}
		configure()
	}
}
