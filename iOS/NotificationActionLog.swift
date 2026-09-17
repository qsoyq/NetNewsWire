//
//  NotificationActionLog.swift
//  NetNewsWire-iOS
//

import Foundation
import ErrorLog

/// Diagnostics for notification actions, especially group mark-as-read.
/// Uses the same in-app error log the media path writes to, so a hang that
/// never reaches Console still leaves a trail.
enum NotificationActionLog {

	static let sourceName = "Notification Action"
	static let sourceID = 101

	static func log(_ level: ErrorLogLevel, operation: String, message: String) {
		guard level.rawValue >= AppDefaults.shared.errorLogLevel.rawValue else {
			return
		}
		let userInfo = ErrorLogUserInfoKey.userInfo(sourceName: sourceName, sourceID: sourceID, operation: operation, errorMessage: message, level: level)
		NotificationCenter.default.post(name: .appDidEncounterError, object: nil, userInfo: userInfo)
	}
}
