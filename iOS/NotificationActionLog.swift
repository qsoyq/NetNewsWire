//
//  NotificationActionLog.swift
//  NetNewsWire-iOS
//

import Foundation
import ErrorLog
import os

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

/// Detects periods where work scheduled on the main queue cannot run. It is
/// active only around foreground lifecycle work so normal background suspension
/// is not reported as a stall.
final class TimelineMainThreadWatchdog: @unchecked Sendable {

	static let shared = TimelineMainThreadWatchdog()

	private struct State: Sendable {
		var isActive = false
		var pingIsOutstanding = false
	}

	private let state = OSAllocatedUnfairLock(initialState: State())
	private let queue = DispatchQueue(label: "Timeline Performance Watchdog", qos: .utility)
	private let timer: DispatchSourceTimer

	private init() {
		let timer = DispatchSource.makeTimerSource(queue: queue)
		self.timer = timer
		timer.schedule(deadline: .now() + 0.05, repeating: 0.05, leeway: .milliseconds(10))
		timer.setEventHandler { [weak self] in
			self?.pingMainQueue()
		}
		timer.resume()
	}

	func setActive(_ isActive: Bool) {
		state.withLock { state in
			state.isActive = isActive
			if !isActive {
				state.pingIsOutstanding = false
			}
		}
	}

	private func pingMainQueue() {
		let shouldPing = state.withLock { state -> Bool in
			guard state.isActive, !state.pingIsOutstanding else {
				return false
			}
			state.pingIsOutstanding = true
			return true
		}
		guard shouldPing else {
			return
		}

		let startUptime = ProcessInfo.processInfo.systemUptime
		DispatchQueue.main.async { [weak self] in
			guard let self else {
				return
			}
			let delay = ProcessInfo.processInfo.systemUptime - startUptime
			let wasActive = state.withLock { state -> Bool in
				state.pingIsOutstanding = false
				return state.isActive
			}
			guard wasActive, delay >= 0.1 else {
				return
			}
			PerformanceDiagnosticLog.event(
				operation: "Main thread stall",
				message: String(format: "delay_ms=%.1f phase=%@", delay * 1_000, PerformanceDiagnosticLog.currentPhase),
				level: .warning
			)
		}
	}
}
