import SwiftUI

enum ArticleSetting: String, CaseIterable, Identifiable {
	case doubleTapToGoBack
	case automaticallyExpandArticleDetails
	case lockArticlePageDirection

	var id: String { rawValue }
	var title: String {
		switch self {
		case .doubleTapToGoBack: return NSLocalizedString("Double-Tap to Go Back", comment: "Article settings")
		case .lockArticlePageDirection: return NSLocalizedString("Lock Page Direction", comment: "Keep the article page layout left-to-right")
		case .automaticallyExpandArticleDetails: return NSLocalizedString("Automatically Expand Collapsed Content", comment: "Automatically expand article details elements")
		}
	}
	var accessibilityIdentifier: String {
		switch self {
		case .doubleTapToGoBack: return "articles.doubleTapToGoBack"
		case .lockArticlePageDirection: return "articles.lockPageDirection"
		case .automaticallyExpandArticleDetails: return "articles.autoExpandDetails"
		}
	}
	var keyPath: ReferenceWritableKeyPath<AppDefaults, Bool> {
		switch self {
		case .doubleTapToGoBack: return \.doubleTapToGoBack
		case .lockArticlePageDirection: return \.lockArticlePageDirection
		case .automaticallyExpandArticleDetails: return \.automaticallyExpandArticleDetails
		}
	}
}

@MainActor final class ArticleSettingsModel: ObservableObject {
	func binding(for setting: ArticleSetting) -> Binding<Bool> {
		Binding {
			AppDefaults.shared[keyPath: setting.keyPath]
		} set: { [weak self] value in
			self?.objectWillChange.send()
			AppDefaults.shared[keyPath: setting.keyPath] = value
		}
	}
}

@MainActor struct ArticleSettingsView: View {
	@StateObject private var model = ArticleSettingsModel()

	var body: some View {
		Form {
			ForEach(ArticleSetting.allCases) { setting in
				Toggle(setting.title, isOn: model.binding(for: setting))
					.accessibilityIdentifier(setting.accessibilityIdentifier)
			}
		}
		.navigationTitle(NSLocalizedString("Article Settings", comment: "Article settings title"))
		.onAppear { model.objectWillChange.send() }
	}
}
