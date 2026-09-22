//
//  ErrorLogTable.swift
//  ErrorLog
//
//  Created by Brent Simmons on 3/11/26.
//

import Foundation
import RSDatabase
import RSDatabaseObjC

struct ErrorLogTable {

	static let name = "errors"

	static func insertEntry(sourceName: String, sourceID: Int, operation: String, fileName: String, functionName: String, lineNumber: Int, errorMessage: String, level: ErrorLogLevel, database: FMDatabase) {
		let dictionary: DatabaseDictionary = [
			ErrorLogEntry.DatabaseKey.date: Date().timeIntervalSince1970,
			ErrorLogEntry.DatabaseKey.sourceName: sourceName,
			ErrorLogEntry.DatabaseKey.sourceID: sourceID,
			ErrorLogEntry.DatabaseKey.operation: operation,
			ErrorLogEntry.DatabaseKey.fileName: fileName,
			ErrorLogEntry.DatabaseKey.functionName: functionName,
			ErrorLogEntry.DatabaseKey.lineNumber: lineNumber,
			ErrorLogEntry.DatabaseKey.errorMessage: errorMessage,
			ErrorLogEntry.DatabaseKey.level: level.rawValue
		]
		database.insertRow(dictionary, insertType: .normal, tableName: name)
	}

	static func allEntries(database: FMDatabase) -> [ErrorLogEntry] {
		let sql = "select * from \(name) order by id asc"
		guard let resultSet = database.executeQuery(sql, withArgumentsIn: nil) else {
			return []
		}
		return resultSet.compactMap(entryWithRow)
	}

	static func entries(limit: Int, beforeID: Int?, database: FMDatabase) -> [ErrorLogEntry] {
		guard limit > 0 else {
			return []
		}

		let sql: String
		let parameters: [Any]
		if let beforeID {
			sql = "select * from \(name) where id < ? order by id desc limit ?"
			parameters = [beforeID, limit]
		} else {
			sql = "select * from \(name) order by id desc limit ?"
			parameters = [limit]
		}
		guard let resultSet = database.executeQuery(sql, withArgumentsIn: parameters) else {
			return []
		}
		return resultSet.compactMap(entryWithRow)
	}

	static func entryCount(database: FMDatabase) -> Int {
		guard let resultSet = database.executeQuery("select count(*) from \(name)", withArgumentsIn: nil) else {
			return 0
		}
		defer { resultSet.close() }
		guard resultSet.next() else {
			return 0
		}
		return Int(resultSet.longLongInt(forColumnIndex: 0))
	}

	static func deleteAllEntries(database: FMDatabase) {
		database.executeUpdateInTransaction("delete from \(name)")
	}
}

private extension ErrorLogTable {

	static func entryWithRow(_ row: FMResultSet) -> ErrorLogEntry? {
		guard let sourceName = row.string(forColumn: ErrorLogEntry.DatabaseKey.sourceName),
			  let errorMessage = row.string(forColumn: ErrorLogEntry.DatabaseKey.errorMessage) else {
			return nil
		}

		let id = Int(row.longLongInt(forColumn: ErrorLogEntry.DatabaseKey.id))
		let date = Date(timeIntervalSince1970: row.double(forColumn: ErrorLogEntry.DatabaseKey.date))
		let sourceID = Int(row.int(forColumn: ErrorLogEntry.DatabaseKey.sourceID))
		let operation = row.string(forColumn: ErrorLogEntry.DatabaseKey.operation) ?? ""
		let fileName = row.string(forColumn: ErrorLogEntry.DatabaseKey.fileName) ?? ""
		let functionName = row.string(forColumn: ErrorLogEntry.DatabaseKey.functionName) ?? ""
		let lineNumber = Int(row.int(forColumn: ErrorLogEntry.DatabaseKey.lineNumber))

		let level = ErrorLogLevel(rawValue: Int(row.int(forColumn: ErrorLogEntry.DatabaseKey.level))) ?? .error
		return ErrorLogEntry(id: id, date: date, sourceName: sourceName, sourceID: sourceID, operation: operation, fileName: fileName, functionName: functionName, lineNumber: lineNumber, errorMessage: errorMessage, level: level)
	}
}
