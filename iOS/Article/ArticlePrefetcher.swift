//
//  ArticlePrefetcher.swift
//  NetNewsWire-iOS
//
//  Created by NetNewsWire on 2026/04/14.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import UIKit
import Articles
import RSCore

@MainActor final class ArticlePrefetcher: NSObject {

	static let shared = ArticlePrefetcher()

	private var lastPrefetchedArticleID: String?
	private(set) var previewTask: Task<Void, Never>?
	private var lastPreviewArticleID: String?
	private let previewService: VideoPreviewService
	private weak var previewCoordinator: SceneCoordinator?
	private var previewArticle: Article?

	init(previewService: VideoPreviewService = .shared) {
		self.previewService = previewService
		super.init()
		NotificationCenter.default.addObserver(self, selector: #selector(previewSettingsChanged), name: .videoPreviewSettingsDidChange, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(suspendPreviewPrefetch), name: UIApplication.didEnterBackgroundNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(previewSettingsChanged), name: UIApplication.didBecomeActiveNotification, object: nil)
	}

	deinit {
		previewTask?.cancel()
		NotificationCenter.default.removeObserver(self)
	}

	@objc private func previewSettingsChanged() {
		cancelVideoPreviewPrefetch()
		lastPrefetchedArticleID = nil
		guard let coordinator = previewCoordinator, let article = previewArticle else { return }
		Task { [weak self, weak coordinator] in
			// Run after all settings observers have cancelled their old consumers.
			await Task.yield()
			guard let self, let coordinator, coordinator.currentArticle == article,
				AppDefaults.shared.loadVideoFirstFramePreview, AppDefaults.shared.prefetchNextArticleContent else { return }
			self.prefetchNextArticle(after: article, coordinator: coordinator)
		}
	}

	@objc private func suspendPreviewPrefetch() { cancelVideoPreviewPrefetch() }

	func cancelVideoPreviewPrefetch(clearContext: Bool = false) {
		previewTask?.cancel()
		previewTask = nil
		lastPreviewArticleID = nil
		if clearContext {
			previewCoordinator = nil
			previewArticle = nil
		}
	}

	func prefetchVideoPreviews(html: String, baseURL: URL?, articleID: String) {
		guard AppDefaults.shared.prefetchNextArticleContent, AppDefaults.shared.loadVideoFirstFramePreview else {
			previewTask?.cancel()
			previewTask = nil
			lastPreviewArticleID = nil
			return
		}
		guard lastPreviewArticleID != articleID else { return }
		previewTask?.cancel()
		lastPreviewArticleID = articleID
		let urls = VideoPreviewSources.urls(in: html, baseURL: baseURL)
		let service = previewService
		previewTask = Task {
			await withTaskGroup(of: Void.self) { group in
				for url in urls {
					group.addTask {
						_ = try? await service.preview(for: url, priority: .prefetch)
					}
				}
			}
		}
	}

	func prefetchNextArticle(after article: Article?, coordinator: SceneCoordinator) {
		previewCoordinator = coordinator
		previewArticle = article
		guard AppDefaults.shared.prefetchNextArticleContent else { return }
		guard let article, let nextArticle = coordinator.findNextArticle(article) else {
			cancelVideoPreviewPrefetch()
			return
		}
		guard nextArticle.articleID != lastPrefetchedArticleID else { return }
		lastPrefetchedArticleID = nextArticle.articleID

		let theme = ArticleThemesManager.shared.currentTheme
		let rendering = ArticleRenderer.articleHTML(article: nextArticle, theme: theme)
		let substitutions = [
			"title": rendering.title,
			"baseURL": rendering.baseURL,
			"style": rendering.style,
			"body": rendering.html,
			"windowScrollY": "0"
		]

		var html = try! MacroProcessor.renderedText(withTemplate: ArticleRenderer.page.html, substitutions: substitutions)
		html = ArticleRenderingSpecialCases.filterHTMLIfNeeded(baseURL: rendering.baseURL, html: html)
		prefetchVideoPreviews(html: html, baseURL: URL(string: rendering.baseURL), articleID: nextArticle.articleID)

		// Extract and cache image URLs
		let (_, uncachedImageURLs) = VideoCacheHTMLRewriter.rewriteImagesForCaching(html)
		if !uncachedImageURLs.isEmpty {
			VideoCacheSchemeHandler.cacheURLsInBackground(uncachedImageURLs)
		}

		// Also prefetch videos if video caching is enabled
		if AppDefaults.shared.cacheVideoContent {
			let (_, uncachedVideoURLs) = VideoCacheHTMLRewriter.rewriteForCaching(html)
			if !uncachedVideoURLs.isEmpty {
				VideoCacheSchemeHandler.cacheURLsInBackground(uncachedVideoURLs)
			}
		}

	}
}
