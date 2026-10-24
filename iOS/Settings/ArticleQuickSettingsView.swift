import SwiftUI
import UIKit

enum ArticleQuickSettingsDestination: String, CaseIterable {
	case article
	case media
	case translation
	case cache

	var title: String {
		switch self {
		case .article: return NSLocalizedString("Article Settings", comment: "Article settings title")
		case .media: return NSLocalizedString("Media", comment: "Media settings title")
		case .translation: return ArticleTranslationStrings.text("Article Translation")
		case .cache: return NSLocalizedString("Cache", comment: "Cache settings title")
		}
	}

	var symbolName: String {
		switch self {
		case .article: return "doc.text"
		case .media: return "photo.on.rectangle"
		case .translation: return "character.book.closed"
		case .cache: return "externaldrive"
		}
	}

	var identifier: String { "article.quickSettings.\(rawValue)" }
}

struct ArticleQuickSettingsView: View {
	let destination: ArticleQuickSettingsDestination
	let close: () -> Void

	var body: some View {
		NavigationStack {
			settings
				.navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .cancellationAction) {
						Button(destination == .translation ? NSLocalizedString("Cancel Quick Settings", comment: "Discard translation settings draft") : NSLocalizedString("Close Quick Settings", comment: "Close article settings"), action: close)
							.accessibilityIdentifier("article.quickSettings.close")
					}
				}
				.accessibilityIdentifier(destination.identifier)
		}
	}

	@ViewBuilder private var settings: some View {
		switch destination {
		case .article: ArticleSettingsView()
		case .media: MediaSettingsView()
		case .translation: ArticleTranslationSettingsView(onSave: close)
		case .cache: CacheSettingsView()
		}
	}
}

final class ArticleQuickSettingsViewController: UIHostingController<ArticleQuickSettingsView>, UIAdaptivePresentationControllerDelegate {
	var onDismiss: (() -> Void)?

	init(destination: ArticleQuickSettingsDestination) {
		super.init(rootView: ArticleQuickSettingsView(destination: destination, close: {}))
		rootView = ArticleQuickSettingsView(destination: destination) { [weak self] in
			self?.close()
		}
		modalPresentationStyle = .formSheet
		presentationController?.delegate = self
	}

	@MainActor required dynamic init?(coder aDecoder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func close() {
		guard !isBeingDismissed else {
			return
		}
		dismiss(animated: true) { [weak self] in self?.didDismiss() }
	}

	override func viewDidDisappear(_ animated: Bool) {
		super.viewDidDisappear(animated)
		// Also handle dismissal initiated by the scene, without treating a covering alert as a close.
		if presentingViewController == nil {
			didDismiss()
		}
	}

	func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
		didDismiss()
	}

	private func didDismiss() {
		let callback = onDismiss
		onDismiss = nil
		callback?()
	}
}
