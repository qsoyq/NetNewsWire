//
//  ErrorLogEntry.swift
//  ErrorLog
//
//  Created by Brent Simmons on 3/11/26.
//

import Foundation
import RSDatabase

public enum ErrorLogLevel: Int, CaseIterable, Sendable {
	case debug = 0
	case info = 1
	case warning = 2
	case error = 3

	public var name: String {
		switch self {
		case .debug: "Debug"
		case .info: "Info"
		case .warning: "Warning"
		case .error: "Error"
		}
	}
}

public struct ErrorLogEntry: Sendable {

	public let id: Int
	public let date: Date
	public let sourceName: String
	public let sourceID: Int // 0-99 reserved for AccountType.rawValue. 100 and up for other components.
	public let operation: String
	public let fileName: String
	public let functionName: String
	public let lineNumber: Int
	public let errorMessage: String
	public let level: ErrorLogLevel

	public init(id: Int, date: Date, sourceName: String, sourceID: Int, operation: String, fileName: String, functionName: String, lineNumber: Int, errorMessage: String, level: ErrorLogLevel = .error) {
		self.id = id
		self.date = date
		self.sourceName = sourceName
		self.sourceID = sourceID
		self.operation = operation
		self.fileName = fileName
		self.functionName = functionName
		self.lineNumber = lineNumber
		self.errorMessage = errorMessage
		self.level = level
	}

	struct DatabaseKey {
		static let id = "id"
		static let date = "date"
		static let sourceName = "sourceName"
		static let sourceID = "sourceID"
		static let operation = "operation"
		static let fileName = "fileName"
		static let functionName = "functionName"
		static let lineNumber = "lineNumber"
		static let errorMessage = "errorMessage"
		static let level = "level"
	}

	func databaseDictionary() -> DatabaseDictionary {
		[
			DatabaseKey.date: date.timeIntervalSince1970,
			DatabaseKey.sourceName: sourceName,
			DatabaseKey.sourceID: sourceID,
			DatabaseKey.operation: operation,
			DatabaseKey.fileName: fileName,
			DatabaseKey.functionName: functionName,
			DatabaseKey.lineNumber: lineNumber,
			DatabaseKey.errorMessage: errorMessage
		]
	}
}
