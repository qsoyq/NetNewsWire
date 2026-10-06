import Foundation
@preconcurrency import WebKit

@MainActor final class ArticleTranslationController: NSObject, WKScriptMessageHandler {
	static let contentWorld = WKContentWorld.world(name: "NetNewsWireTranslation")
	static var userScript: WKUserScript? {
		guard let url = Bundle.main.url(forResource: "translation", withExtension: "js"),
			let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
		return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: contentWorld)
	}

	private weak var webView: WKWebView?
	private var documentID = UUID().uuidString
	private var operationID = UUID()
	private var setupTask: Task<Void, Never>?
	private var translationTask: Task<Void, Never>?
	private var isReady = false
	private var isActive = false
	private var isTranslating = false
	private var shouldAutomaticallyTranslate = true
	private var articleID: String?

	override init() {
		super.init()
		NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: ArticleTranslationSettings.didChange, object: nil)
	}

	deinit {
		setupTask?.cancel()
		translationTask?.cancel()
		NotificationCenter.default.removeObserver(self)
	}

	func documentWillChange() {
		setupTask?.cancel()
		translationTask?.cancel()
		operationID = UUID()
		documentID = UUID().uuidString
		isReady = false
		isTranslating = false
		shouldAutomaticallyTranslate = true
	}

	func documentDidLoad(_ webView: WKWebView, articleID: String? = nil) {
		documentWillChange()
		self.articleID = articleID
		if self.webView !== webView {
			self.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "articleTranslation", contentWorld: Self.contentWorld)
			self.webView = webView
			webView.configuration.userContentController.removeScriptMessageHandler(forName: "articleTranslation", contentWorld: Self.contentWorld)
			webView.configuration.userContentController.add(self, contentWorld: Self.contentWorld, name: "articleTranslation")
		}
		let id = documentID
		let preferences = ArticleTranslationSettings.preferences
		let labels = [
			"title": ArticleTranslationStrings.text("Translation"),
			"translate": ArticleTranslationStrings.text("Translate"),
			"retry": ArticleTranslationStrings.text("Retry Translation"),
			"stop": ArticleTranslationStrings.text("Stop"),
			"restore": ArticleTranslationStrings.text("Show Original"),
			"working": ArticleTranslationStrings.text("Translating…"),
			"done": ArticleTranslationStrings.text("Translated"),
			"paused": ArticleTranslationStrings.text("Translation paused"),
			"failed": ArticleTranslationStrings.text("Translation failed"),
			"original": ArticleTranslationStrings.text("Original")
		]
		setupTask = Task { [weak self] in
			guard let self else { return }
			do {
				_ = try await webView.callAsyncJavaScript("window.nnwTranslation.configure(configuration);", arguments: ["configuration": [
					"documentID": id, "enabled": preferences.isEnabled, "manualEnabled": preferences.manuallyTranslate,
					"displayMode": preferences.displayMode.rawValue, "languageTag": preferences.language.languageTag, "labels": labels
				]], in: nil, contentWorld: Self.contentWorld)
				guard !Task.isCancelled, id == self.documentID else { return }
				self.isReady = true
				self.startAutomaticallyIfNeeded()
			} catch {
				// A replaced or terminated document will be configured on its next successful load.
			}
		}
	}

	func setActive(_ active: Bool) {
		isActive = active
		if active {
			startAutomaticallyIfNeeded()
		} else if isTranslating {
			stop()
			shouldAutomaticallyTranslate = true
		}
	}

	private func startAutomaticallyIfNeeded() {
		guard isReady, isActive, shouldAutomaticallyTranslate, ArticleTranslationSettings.preferences.automaticallyTranslate else { return }
		startTranslation()
	}

	private func startTranslation() {
		guard isReady, isActive, !isTranslating else { return }
		isTranslating = true
		shouldAutomaticallyTranslate = false
		operationID = UUID()
		let operation = operationID
		let document = documentID
		updateState("running")
		translationTask = Task { [weak self] in
			guard let self, let webView = self.webView else { return }
			do {
				let configuration = try ArticleTranslationSettings.configuration()
				let snapshot = try await webView.callAsyncJavaScript("return window.nnwTranslation.collect();", arguments: [:], in: nil, contentWorld: Self.contentWorld)
				guard let json = snapshot as? String else { throw ArticleTranslationError.invalidResponse }
				let segments = try JSONDecoder().decode([ArticleTranslationSegment].self, from: Data(json.utf8))
				guard self.isCurrent(operation, document: document) else { return }
				let preferences = ArticleTranslationSettings.preferences
				try await ArticleTranslationService.shared.translate(segments, articleID: self.articleID, configuration: configuration, maxConcurrentRequests: preferences.concurrentRequests) { [weak self] translations, completed, total in
					guard let self else { throw CancellationError() }
					try await self.receive(translations, completed: completed, total: total, operation: operation, document: document)
				}
				guard self.isCurrent(operation, document: document) else { return }
				self.isTranslating = false
				self.translationTask = nil
				self.updateState("translated")
			} catch {
				guard self.isCurrent(operation, document: document) else { return }
				self.isTranslating = false
				self.translationTask = nil
				if error is CancellationError || (error as? URLError)?.code == .cancelled {
					self.updateState("paused")
				} else {
					self.updateState("error", detail: error.localizedDescription)
				}
			}
		}
	}

	private func isCurrent(_ operation: UUID, document: String) -> Bool {
		operation == operationID && document == documentID && isActive
	}

	private func receive(_ translations: [ArticleTranslationSegment], completed: Int, total: Int, operation: UUID, document: String) async throws {
		try Task.checkCancellation()
		guard isCurrent(operation, document: document), let webView else { throw CancellationError() }
		let values = translations.map { ["id": $0.id, "text": $0.text] }
		_ = try await webView.callAsyncJavaScript("window.nnwTranslation.apply(documentID, translations);", arguments: ["documentID": document, "translations": values], in: nil, contentWorld: Self.contentWorld)
		guard isCurrent(operation, document: document) else { throw CancellationError() }
		let progress = String.localizedStringWithFormat(ArticleTranslationStrings.text("Translating %ld of %ld paragraphs"), completed, total)
		updateState("running", detail: progress)
	}

	private func updateState(_ state: String, detail: String = "") {
		webView?.callAsyncJavaScript("window.nnwTranslation.setState(documentID, state, detail);", arguments: ["documentID": documentID, "state": state, "detail": detail], in: nil, in: Self.contentWorld, completionHandler: nil)
	}

	private func stop() {
		translationTask?.cancel()
		translationTask = nil
		operationID = UUID()
		isTranslating = false
		updateState("paused")
	}

	func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
		guard message.webView === webView, message.frameInfo.isMainFrame, isActive,
			let body = message.body as? [String: String], body["documentID"] == documentID else { return }
		switch body["action"] {
		case "translate":
			guard ArticleTranslationSettings.preferences.isEnabled else { return }
			startTranslation()
		case "stop":
			stop()
		case "restore":
			stop()
			shouldAutomaticallyTranslate = false
			webView?.callAsyncJavaScript("window.nnwTranslation.restore(documentID);", arguments: ["documentID": documentID], in: nil, in: Self.contentWorld, completionHandler: nil)
		default:
			break
		}
	}

	@objc private func settingsChanged(_ notification: Notification) {
		guard isReady, let webView else { return }
		documentDidLoad(webView)
	}
}

enum ArticleTranslationStrings {
	static func text(_ key: String) -> String {
		NSLocalizedString(key, tableName: "ArticleTranslation", comment: "Article translation")
	}
}
