import SwiftUI

struct ArticleTranslationSettingsView: View {
	@Environment(\.dismiss) private var dismiss
	@State private var preferences = ArticleTranslationSettings.preferences
	@State private var apiKey = ""
	@State private var isKeyVisible = false
	@State private var errorMessage: String?
	@State private var didLoadKey = false

	var body: some View {
		Form {
			Section {
				Toggle(ArticleTranslationStrings.text("Automatically Translate"), isOn: $preferences.automaticallyTranslate)
				Toggle(ArticleTranslationStrings.text("Show Translation Button"), isOn: $preferences.manuallyTranslate)
				Picker(ArticleTranslationStrings.text("Translation Display"), selection: $preferences.displayMode) {
					ForEach(ArticleTranslationDisplayMode.allCases) { mode in
						Text(mode.title).tag(mode)
					}
				}
			} header: {
				Text(ArticleTranslationStrings.text("Translation"))
			} footer: {
				Text(ArticleTranslationStrings.text("Translate automatically when you open an article, or use the translation button. Choose to show translations below the original or replace the original. Article titles stay unchanged."))
			}
			Section {
				TextField(ArticleTranslationStrings.text("Base URL"), text: $preferences.baseURL)
					.keyboardType(.URL)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.accessibilityLabel("Base URL")
				HStack {
					Text(ArticleTranslationStrings.text("Path"))
					TextField(ArticleTranslationPreferences.defaultPath, text: $preferences.path)
						.keyboardType(.URL)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.multilineTextAlignment(.trailing)
						.accessibilityIdentifier("translation.path")
				}
				HStack {
					Group {
						if isKeyVisible {
							TextField(ArticleTranslationStrings.text("API Key"), text: $apiKey)
						} else {
							SecureField(ArticleTranslationStrings.text("API Key"), text: $apiKey)
						}
					}
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					Button {
						isKeyVisible.toggle()
					} label: {
						Image(systemName: isKeyVisible ? "eye.slash" : "eye")
							.frame(minWidth: 44, minHeight: 44)
					}
					.buttonStyle(.borderless)
					.accessibilityLabel(ArticleTranslationStrings.text(isKeyVisible ? "Hide API Key" : "Show API Key"))
					.accessibilityIdentifier("translation.keyVisibility")
				}
				TextField(ArticleTranslationStrings.text("Model"), text: $preferences.model)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
				Picker(ArticleTranslationStrings.text("Target Language"), selection: $preferences.language) {
					ForEach(ArticleTranslationLanguage.allCases) { language in
						Text(language.title).tag(language)
					}
				}
				Picker(ArticleTranslationStrings.text("Concurrent Requests"), selection: $preferences.concurrentRequests) {
					ForEach(1...8, id: \.self) { value in Text("\(value)").tag(value) }
				}
			} header: {
				Text(ArticleTranslationStrings.text("Translation Service"))
			} footer: {
				Text(ArticleTranslationStrings.text("Base URL and Path form the request address. An empty Path uses /responses. Article text is sent directly to this service. Your API key is saved in Keychain."))
			}
			Section {
				Button(ArticleTranslationStrings.text("Clear Translation Cache"), role: .destructive) {
					Task { await ArticleTranslationService.shared.clearCache() }
				}
			} footer: {
				Text(ArticleTranslationStrings.text("Saved translations are reused for the same article and service settings."))
			}
			if let errorMessage {
				Section {
					Text(errorMessage).foregroundStyle(.red)
				}
			}
		}
		.navigationTitle(ArticleTranslationStrings.text("Article Translation"))
		.toolbar {
			ToolbarItem(placement: .confirmationAction) {
				Button(ArticleTranslationStrings.text("Save")) {
					do {
						try ArticleTranslationSettings.save(preferences, apiKey: apiKey)
						dismiss()
					} catch {
						errorMessage = error.localizedDescription
					}
				}.disabled(!didLoadKey)
			}
		}
		.onAppear {
			guard !didLoadKey else { return }
			do {
				apiKey = try ArticleTranslationSettings.apiKey()
				didLoadKey = true
			} catch {
				errorMessage = error.localizedDescription
			}
		}
	}
}
