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
		setupTask = Task { [weak self, weak webView] in
			guard let self, let webView else { return }
			do {
				_ = try await webView.callAsyncJavaScript("window.nnwVideoPreview.configure(id, enabled);", arguments: ["id": id, "enabled": enabled], in: nil, contentWorld: Self.contentWorld)
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

	@objc private func settingsChanged() {
		guard lastEnabled != AppDefaults.shared.loadVideoFirstFramePreview else { return }
		lastEnabled = AppDefaults.shared.loadVideoFirstFramePreview
		documentID = UUID().uuidString
		attempted.removeAll()
		configure()
	}
}
