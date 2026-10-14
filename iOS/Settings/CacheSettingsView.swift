import SwiftUI
import Images

@MainActor final class CacheSettingsModel: ObservableObject {
	@Published var showsMediaCacheConfirmation = false
	@Published var showsAvatarCacheConfirmation = false
	@Published private(set) var isClearingCache = false
	@Published var errorMessage: String?

	func requestMediaCacheClear() {
		showsMediaCacheConfirmation = true
	}

	func requestAvatarCacheClear() {
		showsAvatarCacheConfirmation = true
	}

	func clearMediaCache() async {
		guard !isClearingCache else { return }
		showsMediaCacheConfirmation = false
		isClearingCache = true
		defer { isClearingCache = false }
		VideoCacheDatabase.shared.clearAll()
		await VideoPreviewService.shared.clearCache()
	}

	func clearAvatarCache() async {
		guard !isClearingCache else { return }
		showsAvatarCacheConfirmation = false
		isClearingCache = true
		defer { isClearingCache = false }
		do {
			try await AuthorAvatarDownloader.shared.clearCache()
			try await ImageDownloader.shared.clearCache()
			FeedIconDownloader.shared.clearCache()
			try await FaviconDownloader.shared.clearCache()
			await ImageMetadataDatabase.shared.clearCache()
			IconImageCache.shared.emptyCache()
		} catch {
			errorMessage = error.localizedDescription
		}
	}
}

@MainActor struct CacheSettingsView: View {
	@StateObject private var model: CacheSettingsModel

	init(model: CacheSettingsModel = CacheSettingsModel()) {
		_model = StateObject(wrappedValue: model)
	}

	var body: some View {
		Form {
			Section {
				Button(NSLocalizedString("Clear Media Cache", comment: "Media cache action"), role: .destructive) {
					model.requestMediaCacheClear()
				}
				.disabled(model.isClearingCache)
				.accessibilityIdentifier("cache.clearMedia")

				Button(NSLocalizedString("Clear Translation Cache", comment: "Translation cache action"), role: .destructive) {
					Task { await ArticleTranslationService.shared.clearCache() }
				}
				.disabled(model.isClearingCache)
				.accessibilityIdentifier("cache.clearTranslation")

				Button(NSLocalizedString("Clear Avatar Cache", comment: "Avatar cache action"), role: .destructive) {
					model.requestAvatarCacheClear()
				}
				.disabled(model.isClearingCache)
				.accessibilityIdentifier("cache.clearAvatar")
			} header: {
				Text(NSLocalizedString("Cached Content", comment: "Cache settings section"))
			} footer: {
				Text(NSLocalizedString("Downloaded images and avatars expire after three days and are refreshed when needed. Clearing a cache does not remove articles or feed subscriptions.", comment: "Cache settings explanation"))
			}
		}
		.navigationTitle(NSLocalizedString("Cache", comment: "Cache settings title"))
		.alert(NSLocalizedString("Clear Media Cache", comment: "Media cache action"), isPresented: $model.showsMediaCacheConfirmation) {
			Button(NSLocalizedString("Cancel", comment: "Cancel"), role: .cancel) { }
			Button(NSLocalizedString("Clear", comment: "Clear cache action"), role: .destructive) {
				Task { await model.clearMediaCache() }
			}
		} message: {
			Text(NSLocalizedString("Clear cached article images, videos, and first-frame previews?", comment: "Media cache confirmation"))
		}
		.alert(NSLocalizedString("Clear Avatar Cache", comment: "Avatar cache action"), isPresented: $model.showsAvatarCacheConfirmation) {
			Button(NSLocalizedString("Cancel", comment: "Cancel"), role: .cancel) { }
			Button(NSLocalizedString("Clear", comment: "Clear cache action"), role: .destructive) {
				Task { await model.clearAvatarCache() }
			}
		} message: {
			Text(NSLocalizedString("Clear cached author avatars, feed icons, favicons, and icon lookup results?", comment: "Avatar cache confirmation"))
		}
		.alert(NSLocalizedString("Cache Clear Failed", comment: "Cache clear error title"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
			Button(NSLocalizedString("OK", comment: "OK"), role: .cancel) { }
		} message: {
			Text(model.errorMessage ?? "")
		}
	}
}
