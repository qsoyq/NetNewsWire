//
//  ErrorLogDatabaseTests.swift
//  ErrorLog
//
//  Created by Brent Simmons on 3/12/26.
//

import Testing
import Foundation
@testable import ErrorLog

@Suite struct ErrorLogDatabaseTests {

	private func temporaryDatabasePath() -> String {
		let tempDir = NSTemporaryDirectory()
		let filename = "ErrorLogTests-\(UUID().uuidString).db"
		return (tempDir as NSString).appendingPathComponent(filename)
	}

	private func deleteDatabaseFiles(at path: String) {
		for suffix in ["", "-wal", "-shm"] {
			try? FileManager.default.removeItem(atPath: path + suffix)
		}
	}

	@Test func addAndRetrieveEntry() async {
		let path = temporaryDatabasePath()
		defer { deleteDatabaseFiles(at: path) }

		let database = ErrorLogDatabase(databasePath: path)
		await database.addEntry(sourceName: "TestAccount", sourceID: 1, operation: "Refreshing", fileName: "Account/TestFile.swift", functionName: "testFunction()", lineNumber: 42, errorMessage: "Something went wrong")

		let entries = await database.allEntries()
		#expect(entries.count == 1)

		let entry = entries[0]
		#expect(entry.sourceName == "TestAccount")
		#expect(entry.sourceID == 1)
		#expect(entry.operation == "Refreshing")
		#expect(entry.fileName == "Account/TestFile.swift")
		#expect(entry.functionName == "testFunction()")
		#expect(entry.lineNumber == 42)
		#expect(entry.errorMessage == "Something went wrong")
		#expect(entry.level == .error)
		#expect(entry.id > 0)
	}

	@Test func storesLogLevel() async {
		let path = temporaryDatabasePath()
		defer { deleteDatabaseFiles(at: path) }

		let database = ErrorLogDatabase(databasePath: path)
		await database.addEntry(sourceName: "Article Media", sourceID: 100, operation: "Long press", fileName: "WebViewController.swift", functionName: "logMediaEvent", lineNumber: 1, errorMessage: "Detected image target", level: .debug)

		let entries = await database.allEntries()
		#expect(entries.first?.level == .debug)
	}

	@Test func entriesReturnedInInsertionOrder() async {
		let path = temporaryDatabasePath()
		defer { deleteDatabaseFiles(at: path) }

		let database = ErrorLogDatabase(databasePath: path)
		await database.addEntry(sourceName: "First", sourceID: 1, operation: "Refreshing", fileName: "Account/A.swift", functionName: "refresh()", lineNumber: 10, errorMessage: "Error 1")
		await database.addEntry(sourceName: "Second", sourceID: 2, operation: "Syncing", fileName: "Account/B.swift", functionName: "sync()", lineNumber: 20, errorMessage: "Error 2")
		await database.addEntry(sourceName: "Third", sourceID: 3, operation: "Downloading feed", fileName: "Account/C.swift", functionName: "download()", lineNumber: 30, errorMessage: "Error 3")

		let entries = await database.allEntries()
		#expect(entries.count == 3)
		#expect(entries[0].sourceName == "First")
		#expect(entries[1].sourceName == "Second")
		#expect(entries[2].sourceName == "Third")
		#expect(entries[0].id < entries[1].id)
		#expect(entries[1].id < entries[2].id)
	}

	@Test func keepsMoreThanTwoHundredEntries() async {
		let path = temporaryDatabasePath()
		defer { deleteDatabaseFiles(at: path) }

		let database = ErrorLogDatabase(databasePath: path)
		for i in 1...210 {
			await database.addEntry(sourceName: "Account", sourceID: 1, operation: "Refreshing", fileName: "Account/Test.swift", functionName: "refresh()", lineNumber: i, errorMessage: "Error \(i)")
		}

		let entries = await database.allEntries()
		#expect(entries.count == 210)
		#expect(entries[0].errorMessage == "Error 1")
		#expect(entries[209].errorMessage == "Error 210")

		let reopened = ErrorLogDatabase(databasePath: path)
		let entriesAfterReopen = await reopened.allEntries()
		#expect(entriesAfterReopen.count == 210)
	}

	@Test func clearEntriesRemovesAllRows() async {
		let path = temporaryDatabasePath()
		defer { deleteDatabaseFiles(at: path) }

		let database = ErrorLogDatabase(databasePath: path)
		await database.addEntry(sourceName: "First", sourceID: 1, operation: "Refreshing", fileName: "Account/A.swift", functionName: "refresh()", lineNumber: 10, errorMessage: "Error 1")
		await database.addEntry(sourceName: "Second", sourceID: 2, operation: "Syncing", fileName: "Account/B.swift", functionName: "sync()", lineNumber: 20, errorMessage: "Error 2")
		#expect((await database.allEntries()).count == 2)

		await database.clearEntries()
		#expect((await database.allEntries()).isEmpty)
	}
}
