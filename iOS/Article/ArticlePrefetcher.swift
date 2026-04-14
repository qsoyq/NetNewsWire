//
//  ArticlePrefetcher.swift
//  NetNewsWire-iOS
//
//  Created by NetNewsWire on 2026/04/14.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import Articles
import RSCore

@MainActor final class ArticlePrefetcher {

	static let shared = ArticlePrefetcher()

	private var lastPrefetchedArticleID: String?

	func prefetchNextArticle(after article: Article?, coordinator: SceneCoordinator) {
		guard AppDefaults.shared.prefetchNextArticleContent else { return }
		guard let article, let nextArticle = coordinator.findNextArticle(article) else { return }
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
