//
//  DatabaseTests.swift
//  RSDatabase
//
//  Created by Brent Simmons on 4/24/25.
//

import Foundation
import XCTest
@testable import RSDatabase
import RSDatabaseObjC

final class DatabaseTests: XCTestCase {

	func testResumeReturnsBeforeDatabaseReopensAndQueuesCallsInOrder() {
		let reopenStarted = expectation(description: "reopen started")
		let reopenGate = DispatchSemaphore(value: 0)
		let callCompleted = expectation(description: "database call completed")
		let opener = TestDatabaseOpener(reopenStarted: reopenStarted, reopenGate: reopenGate)
		let queue = makeQueue(opener: opener)

		queue.suspend()
		let startTime = CFAbsoluteTimeGetCurrent()
		queue.resume()
		let resumeDuration = CFAbsoluteTimeGetCurrent() - startTime
		XCTAssertLessThan(resumeDuration, 0.1)

		wait(for: [reopenStarted], timeout: 1.0)
		let recorder = CallRecorder()
		queue.runInDatabase { result in
			XCTAssertNotNil(try? result.get())
			recorder.append(1)
		}
		queue.runInDatabase { result in
			XCTAssertNotNil(try? result.get())
			recorder.append(2)
			callCompleted.fulfill()
		}
		XCTAssertEqual(recorder.values, [])

		reopenGate.signal()
		wait(for: [callCompleted], timeout: 1.0)
		XCTAssertEqual(recorder.values, [1, 2])
	}

	func testRepeatedResumeSchedulesSingleReopen() {
		let reopenStarted = expectation(description: "reopen started")
		let reopenGate = DispatchSemaphore(value: 0)
		let completed = expectation(description: "both completions")
		completed.expectedFulfillmentCount = 2
		let opener = TestDatabaseOpener(reopenStarted: reopenStarted, reopenGate: reopenGate)
		let queue = makeQueue(opener: opener)

		queue.suspend()
		queue.resume { completed.fulfill() }
		queue.resume { completed.fulfill() }
		wait(for: [reopenStarted], timeout: 1.0)
		XCTAssertEqual(opener.openCount, 2)

		reopenGate.signal()
		wait(for: [completed], timeout: 1.0)
		XCTAssertEqual(opener.openCount, 2)
	}

	func testSuspendInvalidatesInFlightResume() {
		let reopenStarted = expectation(description: "reopen started")
		let reopenGate = DispatchSemaphore(value: 0)
		let staleCompletion = expectation(description: "stale completion")
		staleCompletion.isInverted = true
		let opener = TestDatabaseOpener(reopenStarted: reopenStarted, reopenGate: reopenGate)
		let queue = makeQueue(opener: opener)

		queue.suspend()
		queue.resume { staleCompletion.fulfill() }
		wait(for: [reopenStarted], timeout: 1.0)
		queue.suspend()
		reopenGate.signal()
		wait(for: [staleCompletion], timeout: 0.2)

		let suspendedCall = expectation(description: "suspended call fails")
		queue.runInDatabase { result in
			if case .success = result {
				XCTFail("Expected a suspended database error")
			}
			suspendedCall.fulfill()
		}
		wait(for: [suspendedCall], timeout: 1.0)

		let cleanupResume = expectation(description: "cleanup resume")
		queue.resume { cleanupResume.fulfill() }
		wait(for: [cleanupResume], timeout: 1.0)
	}

	func testSynchronousCallWaitsForResumeToFinish() {
		let reopenStarted = expectation(description: "reopen started")
		let reopenGate = DispatchSemaphore(value: 0)
		let syncCallCompleted = DispatchSemaphore(value: 0)
		let opener = TestDatabaseOpener(reopenStarted: reopenStarted, reopenGate: reopenGate)
		let queue = makeQueue(opener: opener)

		queue.suspend()
		queue.resume()
		wait(for: [reopenStarted], timeout: 1.0)
		DispatchQueue.global().async {
			queue.runInDatabaseSync { result in
				XCTAssertNotNil(try? result.get())
				syncCallCompleted.signal()
			}
		}
		XCTAssertEqual(syncCallCompleted.wait(timeout: .now() + 0.1), .timedOut)

		reopenGate.signal()
		XCTAssertEqual(syncCallCompleted.wait(timeout: .now() + 1.0), .success)
	}

	private func makeQueue(opener: TestDatabaseOpener) -> DatabaseQueue {
		let path = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
			.appendingPathExtension("sqlite3")
			.path
		return DatabaseQueue(databasePath: path, supportsSuspension: true) { database in
			opener.open(database)
		}
	}
}

private final class TestDatabaseOpener: @unchecked Sendable {
	private let lock = NSLock()
	private var _openCount = 0
	private let reopenStarted: XCTestExpectation
	private let reopenGate: DispatchSemaphore

	var openCount: Int {
		lock.withLock { _openCount }
	}

	init(reopenStarted: XCTestExpectation, reopenGate: DispatchSemaphore) {
		self.reopenStarted = reopenStarted
		self.reopenGate = reopenGate
	}

	func open(_ database: FMDatabase) {
		let openCount = lock.withLock {
			_openCount += 1
			return _openCount
		}
		if openCount == 2 {
			reopenStarted.fulfill()
			reopenGate.wait()
		}
		database.open()
		database.executeStatements("PRAGMA synchronous = 1;")
		database.setShouldCacheStatements(true)
	}
}

private final class CallRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var storage = [Int]()

	var values: [Int] {
		lock.withLock { storage }
	}

	func append(_ value: Int) {
		lock.withLock {
			storage.append(value)
		}
	}
}
