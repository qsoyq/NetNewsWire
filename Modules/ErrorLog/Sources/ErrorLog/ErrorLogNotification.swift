//
//  ErrorLogNotification.swift
//  ErrorLog
//
//  Created by Brent Simmons on 3/12/26.
//

import Foundation
import os

public extension Notification.Name {

	/// Posted when any component encounters an error that should be logged.
	/// UserInfo keys are defined in ErrorLogUserInfoKey.
	static let appDidEncounterError = Notification.Name(rawValue: "AppDidEncounterErrorNotification")
}

public struct ErrorLogUserInfoKey {

	public static let sourceName = "sourceName"
	public static let sourceID = "sourceID" // 0-99 are AccountType raw values. 100 and greater are for other components.
	public static let operation = "operation"
	public static let fileName = "fileName"
	public static let functionName = "functionName"
	public static let lineNumber = "lineNumber"
	public static let errorMessage = "errorMessage"
	public static let level = "level"

	public static func userInfo(sourceName: String, sourceID: Int, operation: String, errorMessage: String, level: ErrorLogLevel = .error, fileName: String = #fileID, functionName: String = #function, lineNumber: Int = #line) -> [String: Any] {
		[
			Self.sourceName: sourceName,
			Self.sourceID: sourceID,
			Self.operation: operation,
			Self.fileName: fileName,
			Self.functionName: functionName,
			Self.lineNumber: lineNumber,
			Self.errorMessage: errorMessage,
			Self.level: level.rawValue
		]
	}
}

public struct PerformanceDiagnosticInterval: Sendable {
	fileprivate let id: Int
	fileprivate let operation: String
	fileprivate let requestID: Int?
	fileprivate let startUptime: TimeInterval
	fileprivate let tracksMainThread: Bool
}

/// A bounded, privacy-safe event stream for diagnosing lifecycle performance
/// without requiring a debugger or Instruments.
public enum PerformanceDiagnosticLog {

	public static let sourceName = "Timeline Performance"
	public static let sourceID = 104

	private struct State: Sendable {
		var sessionID = 0
		var sequence = 0
		var nextRequestID = 0
		var nextIntervalID = 0
		var remainingEvents = 0
		var notificationsEnabled = true
		var currentRequestID: Int?
		var activeStageIDs = [Int]()
		var stageNames = [Int: String]()
	}

	private struct EventContext: Sendable {
		let sessionID: Int
		let sequence: Int
		let requestID: Int?
	}

	private static let state = OSAllocatedUnfairLock(initialState: State())

	@discardableResult public static func beginSession(reason: String, maximumEvents: Int = 500) -> Int {
		beginSession(reason: reason, maximumEvents: maximumEvents, notificationsEnabled: true)
	}

	@discardableResult private static func beginSession(reason: String, maximumEvents: Int, notificationsEnabled: Bool) -> Int {
		let sessionID = state.withLock { state in
			state.sessionID += 1
			state.sequence = 0
			state.nextRequestID = 0
			state.nextIntervalID = 0
			state.remainingEvents = max(1, maximumEvents)
			state.notificationsEnabled = notificationsEnabled
			state.currentRequestID = nil
			state.activeStageIDs.removeAll()
			state.stageNames.removeAll()
			return state.sessionID
		}
		event(operation: "Session", message: "begin reason=\(reason)")
		return sessionID
	}

	@discardableResult public static func beginRequest(kind: String, details: String = "") -> Int {
		let requestID = state.withLock { state in
			state.nextRequestID += 1
			state.currentRequestID = state.nextRequestID
			return state.nextRequestID
		}
		event(operation: "Request", message: joined("begin kind=\(kind)", details), requestID: requestID)
		return requestID
	}

	public static func endRequest(_ requestID: Int, details: String = "") {
		event(operation: "Request", message: joined("end", details), requestID: requestID)
		state.withLock { state in
			if state.currentRequestID == requestID {
				state.currentRequestID = nil
			}
		}
	}

	@discardableResult public static func begin(_ operation: String, details: String = "", requestID: Int? = nil, tracksMainThread: Bool = true) -> PerformanceDiagnosticInterval {
		let startUptime = ProcessInfo.processInfo.systemUptime
		let interval = state.withLock { state in
			state.nextIntervalID += 1
			let interval = PerformanceDiagnosticInterval(
				id: state.nextIntervalID,
				operation: operation,
				requestID: requestID ?? state.currentRequestID,
				startUptime: startUptime,
				tracksMainThread: tracksMainThread
			)
			if tracksMainThread {
				state.activeStageIDs.append(interval.id)
				state.stageNames[interval.id] = operation
			}
			return interval
		}
		event(operation: operation, message: joined("begin", details), requestID: interval.requestID)
		return interval
	}

	public static func end(_ interval: PerformanceDiagnosticInterval, details: String = "") {
		let duration = ProcessInfo.processInfo.systemUptime - interval.startUptime
		state.withLock { state in
			if interval.tracksMainThread {
				state.activeStageIDs.removeAll { $0 == interval.id }
				state.stageNames[interval.id] = nil
			}
		}
		let durationText = String(format: "duration_ms=%.1f", duration * 1_000)
		event(operation: interval.operation, message: joined("end \(durationText)", details), requestID: interval.requestID)
	}

	public static func event(operation: String, message: String, requestID: Int? = nil, level: ErrorLogLevel = .debug, fileName: String = #fileID, functionName: String = #function, lineNumber: Int = #line) {
		guard let result = state.withLock({ state -> (EventContext, Bool)? in
			guard state.remainingEvents > 0 else {
				return nil
			}
			state.remainingEvents -= 1
			state.sequence += 1
			let context = EventContext(sessionID: state.sessionID, sequence: state.sequence, requestID: requestID ?? state.currentRequestID)
			return (context, state.notificationsEnabled)
		}) else {
			return
		}
		let (context, notificationsEnabled) = result
		guard notificationsEnabled else {
			return
		}

		let requestText = context.requestID.map { " request=\($0)" } ?? ""
		let prefixedMessage = "session=\(context.sessionID) seq=\(context.sequence)\(requestText) \(message)"
		let userInfo = ErrorLogUserInfoKey.userInfo(
			sourceName: sourceName,
			sourceID: sourceID,
			operation: operation,
			errorMessage: prefixedMessage,
			level: level,
			fileName: fileName,
			functionName: functionName,
			lineNumber: lineNumber
		)
		NotificationCenter.default.post(name: .appDidEncounterError, object: nil, userInfo: userInfo)
	}

	public static var currentPhase: String {
		state.withLock { state in
			guard let stageID = state.activeStageIDs.last else {
				return "idle"
			}
			return state.stageNames[stageID] ?? "unknown"
		}
	}

	static func beginTestingSession(maximumEvents: Int) {
		_ = beginSession(reason: "test", maximumEvents: maximumEvents, notificationsEnabled: false)
	}

	static var stateForTesting: (sequence: Int, remainingEvents: Int) {
		state.withLock { state in
			(state.sequence, state.remainingEvents)
		}
	}

	private static func joined(_ first: String, _ second: String) -> String {
		second.isEmpty ? first : "\(first) \(second)"
	}
}
