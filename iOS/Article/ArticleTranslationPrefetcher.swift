import Foundation
import Articles
import RSCore
import os

@MainActor final class ArticleTranslationPrefetcher {
	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "ArticleTranslationPrefetcher")
	private(set) var task: Task<Void, Never>?
	private let service: ArticleTranslationService
	private var target: Article?
	private var operationID = UUID()
	private var selectedArticle: Article?
	private var foregroundTask: Task<Void, Never>?

	init(service: ArticleTranslationService = .shared) {
		self.service = service
	}

	deinit {
		task?.cancel()
		foregroundTask?.cancel()
	}

	func cancel() {
		foregroundTask?.cancel()
		foregroundTask = nil
		selectedArticle = nil
		cancelNext()
	}

	private func cancelNext() {
		task?.cancel()
		task = nil
		target = nil
		operationID = UUID()
	}

	func select(_ article: Article?) {
		guard selectedArticle != article else { return }
		foregroundTask?.cancel()
		foregroundTask = nil
		selectedArticle = article
		if target == article {
			// Keep the useful work alive while the reader configures and joins its requests.
			foregroundTask = task
			task = nil
			target = nil
			operationID = UUID()
		} else {
			cancelNext()
		}
	}

	func prefetch(_ article: Article?, size: CGSize) {
		let preferences = ArticleTranslationSettings.preferences
		guard preferences.automaticallyTranslate, preferences.prefetchNextArticleTranslation else {
			cancel()
			return
		}
		guard let article else {
			cancelNext()
			return
		}
		guard target != article || task == nil else { return }
		cancelNext()
		target = article
		let operation = operationID
		let service = service
		task = Task(priority: .utility) { [weak self] in
			do {
				let configuration = try ArticleTranslationSettings.configuration()
				let html = try Self.render(article)
				let document = ArticleTranslationDocument()
				let segments = try await document.segments(html: html.html, baseURL: html.baseURL, preferences: preferences, size: size)
				try Task.checkCancellation()
				try await service.translate(segments, articleID: article.articleID, configuration: configuration,
					maxConcurrentRequests: preferences.concurrentRequests, priority: .background) { _, _, _ in }
			} catch {
				if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
					Self.logger.debug("Next article translation failed: \(error.localizedDescription, privacy: .public)")
				}
			}
			guard let self, self.operationID == operation else { return }
			self.task = nil
			self.target = nil
		}
	}

	static func render(_ article: Article) throws -> (html: String, baseURL: URL?) {
		let rendering = ArticleRenderer.articleHTML(article: article, theme: ArticleThemesManager.shared.currentTheme)
		let substitutions = ["title": rendering.title, "baseURL": rendering.baseURL, "style": rendering.style, "body": rendering.html, "windowScrollY": "0"]
		let html = try MacroProcessor.renderedText(withTemplate: ArticleRenderer.page.html, substitutions: substitutions)
		return (ArticleRenderingSpecialCases.filterHTMLIfNeeded(baseURL: rendering.baseURL, html: html), URL(string: rendering.baseURL))
	}
}
