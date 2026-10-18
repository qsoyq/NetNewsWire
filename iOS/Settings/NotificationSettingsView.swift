import SwiftUI
import UIKit
import UserNotifications

struct NotificationSettingsView: View {
	@AppStorage(KeywordNotificationPreferences.enabledKey) private var keywordNotificationsEnabled = false
	@AppStorage(KeywordNotificationPreferences.keywordsKey) private var keywordsText = ""
	@AppStorage(KeywordNotificationPreferences.ignoresCaseKey) private var ignoresCase = true
	@Environment(\.scenePhase) private var scenePhase
	@State private var permissionDenied = false
	@State private var authorizationError: String?

	var body: some View {
		Form {
			Section {
				Toggle(NSLocalizedString("Keyword Notifications", comment: "Keyword notification switch"), isOn: $keywordNotificationsEnabled)
					.accessibilityIdentifier("notifications.keywords.enabled")
			} footer: {
				Text(NSLocalizedString("Notify when a newly received unread article contains any keyword in its title or body. Feed notifications and keyword matches send only one notification per article, grouped by feed.", comment: "Keyword notifications behavior"))
			}
			Section {
				TextField(NSLocalizedString("One keyword per line", comment: "Keyword entry placeholder"), text: $keywordsText, axis: .vertical)
					.lineLimit(5...12)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.accessibilityLabel(NSLocalizedString("Keywords", comment: "Notification keywords"))
					.accessibilityIdentifier("notifications.keywords.text")
				Toggle(NSLocalizedString("Ignore Case", comment: "Keyword case sensitivity switch"), isOn: $ignoresCase)
					.accessibilityIdentifier("notifications.keywords.ignoreCase")
			} header: {
				Text(NSLocalizedString("Keywords", comment: "Notification keywords"))
			} footer: {
				Text(NSLocalizedString("Enter one keyword or phrase per line. Turn off Ignore Case to match uppercase and lowercase exactly. Changes apply to articles received during future refreshes.", comment: "Keyword entry instructions"))
			}
			Section {
				Button(NSLocalizedString("Open System Settings", comment: "Open system notification settings")) {
					guard let url = URL(string: UIApplication.openSettingsURLString) else {
						return
					}
					UIApplication.shared.open(url)
				}
				.accessibilityIdentifier("notifications.systemSettings")
			} footer: {
				if permissionDenied {
					Text(NSLocalizedString("Notifications are disabled in System Settings. Allow notifications to receive feed and keyword alerts.", comment: "Notification permission denied"))
				}
				if let authorizationError {
					Text(authorizationError)
				}
			}
		}
		.navigationTitle(NSLocalizedString("Notifications", comment: "Notification settings title"))
		.task { await updateAuthorization(requestIfNeeded: keywordNotificationsEnabled) }
		.onChange(of: keywordNotificationsEnabled) { _, enabled in
			if enabled {
				Task { await updateAuthorization(requestIfNeeded: true) }
			}
		}
		.onChange(of: scenePhase) { _, phase in
			if phase == .active {
				Task { await updateAuthorization(requestIfNeeded: false) }
			}
		}
	}

	@MainActor private func updateAuthorization(requestIfNeeded: Bool) async {
		let center = UNUserNotificationCenter.current()
		let settings = await center.notificationSettings()
		authorizationError = nil
		if requestIfNeeded, settings.authorizationStatus == .notDetermined {
			do {
				let granted = try await center.requestAuthorization(options: [.badge, .sound, .alert])
				permissionDenied = !granted
			} catch {
				authorizationError = error.localizedDescription
			}
		} else {
			permissionDenied = settings.authorizationStatus == .denied
		}
	}
}
