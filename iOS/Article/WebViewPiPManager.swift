//
//  WebViewPiPManager.swift
//  NetNewsWire-iOS
//
//  Created by NetNewsWire on 2026/06/03.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation

@MainActor
final class WebViewPiPManager {

	static let shared = WebViewPiPManager()

	private(set) var isPiPActive = false
	private weak var activeWebViewController: WebViewController?
	private var protectedWebViewController: WebViewController?

	private init() {
	}

	func pipDidStart(from webViewController: WebViewController) {
		activeWebViewController = webViewController
		isPiPActive = true
	}

	func pipDidStop(from webViewController: WebViewController) {
		guard activeWebViewController === webViewController else { return }

		isPiPActive = false
		activeWebViewController = nil
		protectedWebViewController?.stopWebViewActivity()
		protectedWebViewController?.setArticle(nil)
		protectedWebViewController = nil
	}

	func isPiPActive(in webViewController: WebViewController) -> Bool {
		return isPiPActive && activeWebViewController === webViewController
	}

	func protect(_ webViewController: WebViewController) {
		guard activeWebViewController === webViewController else { return }

		protectedWebViewController = webViewController
	}
}
