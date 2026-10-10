import SwiftUI

enum MediaSetting: String, CaseIterable, Identifiable {
	case autoFullscreenVideo
	case useNativeVideoPlayer
	case autoplayVideo
	case autoGotoNextAfterVideo
	case pipAutoPlayNextVideo
	case cacheVideoContent
	case loadVideoFirstFramePreview
	case showArticleMediaThumbnails
	case prefetchNextArticleContent

	var id: String { rawValue }
	var title: String {
		switch self {
		case .autoFullscreenVideo: return NSLocalizedString("Play Videos in Full Screen", comment: "Media settings")
		case .useNativeVideoPlayer: return NSLocalizedString("Use Native Video Player", comment: "Media settings")
		case .autoplayVideo: return NSLocalizedString("Autoplay Video", comment: "Media settings")
		case .autoGotoNextAfterVideo: return NSLocalizedString("Go to Next Article After Video Ends", comment: "Media settings")
		case .pipAutoPlayNextVideo: return NSLocalizedString("Autoplay Next Video in PiP", comment: "Media settings")
		case .cacheVideoContent: return NSLocalizedString("Cache Video Content", comment: "Media settings")
		case .loadVideoFirstFramePreview: return NSLocalizedString("Load Video First Frame Preview", comment: "Load video previews")
		case .showArticleMediaThumbnails: return NSLocalizedString("Show Media Thumbnails Above Article", comment: "Media settings")
		case .prefetchNextArticleContent: return NSLocalizedString("Prefetch Next Article", comment: "Media settings")
		}
	}
	var accessibilityIdentifier: String {
		self == .loadVideoFirstFramePreview ? "articles.videoFirstFramePreview" : "media.\(rawValue)"
	}
	var keyPath: ReferenceWritableKeyPath<AppDefaults, Bool> {
		switch self {
		case .autoFullscreenVideo: return \.autoFullscreenVideo
		case .useNativeVideoPlayer: return \.useNativeVideoPlayer
		case .autoplayVideo: return \.autoplayVideo
		case .autoGotoNextAfterVideo: return \.autoGotoNextAfterVideo
		case .pipAutoPlayNextVideo: return \.pipAutoPlayNextVideo
		case .cacheVideoContent: return \.cacheVideoContent
		case .loadVideoFirstFramePreview: return \.loadVideoFirstFramePreview
		case .showArticleMediaThumbnails: return \.showArticleMediaThumbnails
		case .prefetchNextArticleContent: return \.prefetchNextArticleContent
		}
	}
}

@MainActor final class MediaSettingsModel: ObservableObject {
	@Published var showsCacheConfirmation = false
	@Published private(set) var isClearingCache = false
	private let clearCaches: @MainActor () async -> Void

	init(clearCaches: @escaping @MainActor () async -> Void = {
		VideoCacheDatabase.shared.clearAll()
		await VideoPreviewService.shared.clearCache()
	}) {
		self.clearCaches = clearCaches
	}

	func binding(for setting: MediaSetting) -> Binding<Bool> {
		Binding {
			AppDefaults.shared[keyPath: setting.keyPath]
		} set: { [weak self] value in
			self?.objectWillChange.send()
			AppDefaults.shared[keyPath: setting.keyPath] = value
		}
	}

	func requestCacheClear() { showsCacheConfirmation = true }
	func cancelCacheClear() { showsCacheConfirmation = false }
	func confirmCacheClear() async {
		guard !isClearingCache else { return }
		showsCacheConfirmation = false
		isClearingCache = true
		defer { isClearingCache = false }
		await clearCaches()
	}
}

@MainActor struct MediaSettingsView: View {
	@StateObject private var model: MediaSettingsModel

	init(model: MediaSettingsModel = MediaSettingsModel()) {
		_model = StateObject(wrappedValue: model)
	}

	var body: some View {
		Form {
			Section {
				settings([.autoFullscreenVideo, .useNativeVideoPlayer, .autoplayVideo, .autoGotoNextAfterVideo, .pipAutoPlayNextVideo])
			} header: {
				Text(NSLocalizedString("Video Playback", comment: "Media settings section"))
			}
			Section {
				settings([.showArticleMediaThumbnails, .cacheVideoContent, .loadVideoFirstFramePreview, .prefetchNextArticleContent])
			} header: {
				Text(NSLocalizedString("Loading and Previews", comment: "Media settings section"))
			} footer: {
				Text(NSLocalizedString("Prefetching loads images for the next article. Videos and first-frame previews follow their own switches. Loading previews and prefetching may use additional data.", comment: "Media prefetch behavior"))
			}
			Section {
				Button(NSLocalizedString("Clear Media Cache", comment: "Media cache action"), role: .destructive) {
					model.requestCacheClear()
				}
				.disabled(model.isClearingCache)
				.accessibilityIdentifier("media.clearCache")
			} header: {
				Text(NSLocalizedString("Media Cache", comment: "Media settings section"))
			}
		}
		.navigationTitle(NSLocalizedString("Media", comment: "Media settings title"))
		.onAppear { model.objectWillChange.send() }
		.alert(NSLocalizedString("Clear Media Cache", comment: "Media cache action"), isPresented: $model.showsCacheConfirmation) {
			Button(NSLocalizedString("Cancel Media Cache Clear", comment: "Cancel media cache clear"), role: .cancel) { model.cancelCacheClear() }
			Button(NSLocalizedString("Confirm Media Cache Clear", comment: "Confirm media cache clear"), role: .destructive) {
				Task { await model.confirmCacheClear() }
			}
		} message: {
			Text(NSLocalizedString("Clear cached article images, videos, and first-frame previews?", comment: "Media cache confirmation"))
		}
	}

	private func settings(_ items: [MediaSetting]) -> some View {
		ForEach(items) { setting in
			Toggle(setting.title, isOn: model.binding(for: setting))
				.accessibilityIdentifier(setting.accessibilityIdentifier)
		}
	}
}
