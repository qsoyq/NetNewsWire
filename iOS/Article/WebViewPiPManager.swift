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
	private var protectedWebViewController: WebViewController?

	private init() {
	}

	func pipDidStart() {
		isPiPActive = true
	}

	func pipDidStop() {
		isPiPActive = false
		protectedWebViewController?.stopWebViewActivity()
		protectedWebViewController?.setArticle(nil)
		protectedWebViewController = nil
	}

	func protect(_ webViewController: WebViewController) {
		protectedWebViewController = webViewController
	}
}
