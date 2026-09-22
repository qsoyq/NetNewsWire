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

	@Test func paginatesNewestEntriesWithoutDuplicates() async {
		let path = temporaryDatabasePath()
		defer { deleteDatabaseFiles(at: path) }

		let database = ErrorLogDatabase(databasePath: path)
		for i in 1...250 {
			await database.addEntry(sourceName: "Source", sourceID: 100, operation: "Page", fileName: "", functionName: "", lineNumber: 0, errorMessage: "Entry \(i)")
		}

		#expect(await database.entryCount() == 250)
		let firstPage = await database.entries(limit: 200)
		#expect(firstPage.count == 200)
		#expect(firstPage.first?.errorMessage == "Entry 250")
		#expect(firstPage.last?.errorMessage == "Entry 51")

		let secondPage = await database.entries(limit: 200, beforeID: firstPage.last?.id)
		#expect(secondPage.count == 50)
		#expect(secondPage.first?.errorMessage == "Entry 50")
		#expect(secondPage.last?.errorMessage == "Entry 1")
		#expect(Set(firstPage.map(\.id)).isDisjoint(with: Set(secondPage.map(\.id))))
	}

	@Test func paginationHandlesEmptyAndZeroLimit() async {
		let path = temporaryDatabasePath()
		defer { deleteDatabaseFiles(at: path) }

		let database = ErrorLogDatabase(databasePath: path)
		#expect(await database.entries(limit: 200).isEmpty)
		#expect(await database.entries(limit: 0).isEmpty)
		#expect(await database.entryCount() == 0)
	}

	@Test func largeLogKeepsFirstPageBoundedAndExportsAllEntries() async throws {
		let path = temporaryDatabasePath()
		defer { deleteDatabaseFiles(at: path) }
		let database = ErrorLogDatabase(databasePath: path)
		let message = String(repeating: "x", count: 160)
		for index in 0..<25_000 {
			await database.addEntry(sourceName: "Test", sourceID: 100, operation: "", fileName: "", functionName: "", lineNumber: 0, errorMessage: "\(index):\(message)")
		}
		let page = await database.entries(limit: 200)
		#expect(page.count == 200)
		#expect(page.first?.errorMessage.hasPrefix("24999:") == true)
		let exported = await database.allEntries()
		#expect(exported.count == 25_000)
		#expect(exported.first?.errorMessage.hasPrefix("0:") == true)
		#expect(exported.map(\.id) == exported.map(\.id).sorted())
		let url = try ErrorLogTextFormatter.writeDiagnosticsFile(entries: exported, header: "NetNewsWire Diagnostics\nCommit: test-build")
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let text = try String(contentsOf: url, encoding: .utf8)
		#expect(text.hasPrefix("NetNewsWire Diagnostics\nCommit: test-build\n\n"))
		#expect(text.components(separatedBy: "] Test: ").count - 1 == 25_000)
		#expect(text.range(of: "Test: 0:")!.lowerBound < text.range(of: "Test: 24999:")!.lowerBound)
		await database.clearEntries()
		#expect(await database.entries(limit: 200, beforeID: page.last?.id).isEmpty)
		#expect(await database.entryCount() == 0)
	}

	@Test func performanceDiagnosticsAreBoundedAndTrackActivePhase() {
		PerformanceDiagnosticLog.beginTestingSession(maximumEvents: 3)
		let interval = PerformanceDiagnosticLog.begin("Sorting")
		#expect(PerformanceDiagnosticLog.currentPhase == "Sorting")
		PerformanceDiagnosticLog.end(interval)
		PerformanceDiagnosticLog.event(operation: "Ignored", message: "over capacity")

		#expect(PerformanceDiagnosticLog.currentPhase == "idle")
		#expect(PerformanceDiagnosticLog.stateForTesting.sequence == 3)
		#expect(PerformanceDiagnosticLog.stateForTesting.remainingEvents == 0)
	}
}
