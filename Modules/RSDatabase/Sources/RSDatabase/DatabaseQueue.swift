//
//  DatabaseQueue.swift
//  RSDatabase
//
//  Created by Brent Simmons on 11/13/19.
//  Copyright © 2019 Brent Simmons. All rights reserved.
//

import Foundation
import os
import SQLite3
import RSDatabaseObjC

/// Manage a serial queue and a SQLite database.
///
/// On iOS, the queue can be suspended
/// in order to support background refreshing.
public final class DatabaseQueue: Sendable {
	private enum LifecycleState {
		case active
		case suspended
		case resuming(Int)
	}

	private struct ResumeRequest: @unchecked Sendable {
		let database: FMDatabase
		let generation: Int
	}

	private enum ResumeAction: @unchecked Sendable {
		case completeImmediately
		case alreadyResuming
		case start(ResumeRequest)
	}

	private struct ResumeResult: Sendable {
		let didResume: Bool
		let completions: [@Sendable () -> Void]
	}

	private struct State: @unchecked Sendable {
		var isCallingDatabase = false
		var lifecycleState = LifecycleState.active
		var lifecycleGeneration = 0
		var resumeCompletions = [@Sendable () -> Void]()
		let database: FMDatabase

		init(_ database: FMDatabase) {
			self.database = database
		}
	}

	private let state: OSAllocatedUnfairLock<State>
	private let databasePath: String
	private let serialDispatchQueue: DispatchQueue
	private let resumeDispatchQueue: DispatchQueue
	private let supportsSuspension: Bool
	private let databaseOpener: @Sendable (FMDatabase) -> Void

	private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "DatabaseQueue")

	public convenience init(databasePath: String) {
		#if os(iOS)
		let supportsSuspension = true
		#else
		let supportsSuspension = false
		#endif
		self.init(databasePath: databasePath, supportsSuspension: supportsSuspension, databaseOpener: Self.openDatabase)
	}

	init(databasePath: String, supportsSuspension: Bool, databaseOpener: @escaping @Sendable (FMDatabase) -> Void) {
		Self.logger.debug("DatabaseQueue: creating with database path \(databasePath)")

		self.serialDispatchQueue = DispatchQueue(label: "DatabaseQueue (Serial) - \(databasePath)")
		self.resumeDispatchQueue = DispatchQueue(label: "DatabaseQueue (Resume) - \(databasePath)", qos: .userInitiated)

		self.databasePath = databasePath
		self.supportsSuspension = supportsSuspension
		self.databaseOpener = databaseOpener
		let database = FMDatabase(path: databasePath)!
		self.state = OSAllocatedUnfairLock(initialState: State(database))

		databaseOpener(database)
	}

	// MARK: - Suspend and Resume

	/// Close the SQLite database and don’t allow database calls until resumed.
	/// This is for iOS, where we need to close the SQLite database in some conditions.
	///
	/// After calling suspend, further database calls fail immediately with
	/// `DatabaseError.isSuspended` instead of blocking on the suspended GCD queue.
	///
	/// On Mac, suspend() and resume() are no-ops, since there isn’t a need for them.
	public func suspend() {
		guard supportsSuspension else {
			return
		}
		Self.logger.info("DatabaseQueue: suspending")
		state.withLock { state in
			switch state.lifecycleState {
			case .suspended:
				Self.logger.info("DatabaseQueue: suspend skipped because already suspended")
			case .active:
				state.lifecycleGeneration += 1
				state.lifecycleState = .suspended
				state.resumeCompletions.removeAll()
				serialDispatchQueue.suspend()
				state.database.close()
			case .resuming:
				// The serial queue is still suspended while the database is reopening.
				// Advancing the generation makes that in-flight reopen stale.
				state.lifecycleGeneration += 1
				state.lifecycleState = .suspended
				state.resumeCompletions.removeAll()
			}
		}
	}

	/// Open the SQLite database away from the caller's thread, then allow queued database calls again.
	/// iOS only — on macOS the optional completion is called immediately.
	public func resume(completion: (@Sendable () -> Void)? = nil) {
		guard supportsSuspension else {
			completion?()
			return
		}

		let action = state.withLock { state -> ResumeAction in
			switch state.lifecycleState {
			case .active:
				Self.logger.info("DatabaseQueue: resume skipped because already resumed")
				return .completeImmediately
			case .resuming:
				if let completion {
					state.resumeCompletions.append(completion)
				}
				return .alreadyResuming
			case .suspended:
				Self.logger.info("DatabaseQueue: scheduling resume")
				let generation = state.lifecycleGeneration
				state.lifecycleState = .resuming(generation)
				if let completion {
					state.resumeCompletions.append(completion)
				}
				return .start(ResumeRequest(database: state.database, generation: generation))
			}
		}

		switch action {
		case .completeImmediately:
			completion?()
			return
		case .alreadyResuming:
			return
		case .start(let request):
			resumeDispatchQueue.async { [self, request] in
				performResume(request)
			}
		}
	}

	private func performResume(_ request: ResumeRequest) {
		let startTime = CFAbsoluteTimeGetCurrent()
		databaseOpener(request.database)

		let result = state.withLock { state -> ResumeResult in
			guard case .resuming(let generation) = state.lifecycleState,
				  generation == request.generation,
				  state.lifecycleGeneration == request.generation else {
				return ResumeResult(didResume: false, completions: [])
			}

			state.lifecycleState = .active
			let completions = state.resumeCompletions
			state.resumeCompletions.removeAll()
			serialDispatchQueue.resume()
			return ResumeResult(didResume: true, completions: completions)
		}

		guard result.didResume else {
			request.database.close()
			Self.logger.info("DatabaseQueue: discarded stale resume")
			return
		}

		let duration = CFAbsoluteTimeGetCurrent() - startTime
		Self.logger.info("DatabaseQueue: resume completed in \(duration, format: .fixed(precision: 3)) seconds")
		for completion in result.completions {
			completion()
		}
	}

	// MARK: - Make Database Calls

	/// Run a DatabaseBlock synchronously. This call will block the main thread
	/// potentially for a while, depending on how long it takes to execute
	/// the DatabaseBlock *and* depending on how many other calls have been
	/// scheduled on the queue. Use sparingly — prefer async versions.
	public func runInDatabaseSync(_ databaseBlock: DatabaseBlock) {
		guard let lifecycleGeneration = enqueueDatabaseCall(databaseBlock) else {
			return
		}
		serialDispatchQueue.sync {
			self.state.withLock { state in
				self._runInDatabase(&state, databaseBlock, false, lifecycleGeneration)
			}
		}
	}

	/// Run a DatabaseBlock asynchronously.
	public func runInDatabase(_ databaseBlock: @escaping DatabaseBlock) {
		guard let lifecycleGeneration = enqueueDatabaseCall(databaseBlock) else {
			return
		}
		serialDispatchQueue.async {
			self.state.withLock { state in
				self._runInDatabase(&state, databaseBlock, false, lifecycleGeneration)
			}
		}
	}

	/// Run a DatabaseBlock wrapped in a transaction synchronously.
	/// Transactions help performance significantly when updating the database.
	/// Nevertheless, it’s best to avoid this because it will block the main thread —
	/// prefer the async `runInTransaction` instead.
	public func runInTransactionSync(_ databaseBlock: @escaping DatabaseBlock) {
		guard let lifecycleGeneration = enqueueDatabaseCall(databaseBlock) else {
			return
		}
		serialDispatchQueue.sync {
			self.state.withLock { state in
				self._runInDatabase(&state, databaseBlock, true, lifecycleGeneration)
			}
		}
	}

	/// Run a DatabaseBlock wrapped in a transaction asynchronously.
	/// Transactions help performance significantly when updating the database.
	public func runInTransaction(_ databaseBlock: @escaping DatabaseBlock) {
		guard let lifecycleGeneration = enqueueDatabaseCall(databaseBlock) else {
			return
		}
		serialDispatchQueue.async {
			self.state.withLock { state in
				self._runInDatabase(&state, databaseBlock, true, lifecycleGeneration)
			}
		}
	}

	/// Run all the lines that start with "create".
	/// Use this to create tables, indexes, etc.
	public func runCreateStatements(_ statements: String) throws {
		nonisolated(unsafe) var error: DatabaseError?

		runInDatabaseSync { result in
			Self.logger.debug("DatabaseQueue: runCreateStatements")

			switch result {
			case .success(let database):
				statements.enumerateLines { (line, stop) in
					if line.lowercased().hasPrefix("create") {
						database.executeStatements(line)
					}
					stop = false
				}
			case .failure(let databaseError):
				error = databaseError
			}
		}

		if let error {
			throw(error)
		}
	}

	/// Compact the database. This should be done from time to time —
	/// weekly-ish? — to keep up the performance level of a database.
	/// Generally a thing to do at startup, if it’s been a while
	/// since the last vacuum() call. You almost certainly want to call
	/// vacuumIfNeeded instead.
	public func vacuum() {
		runInDatabase { result in
			Self.logger.debug("DatabaseQueue: vacuum")
			guard let database = try? result.get() else {
				return
			}
			database.executeStatements("vacuum;")
		}
	}

	/// Vacuum the database if it’s been more than `daysBetweenVacuums` since the last vacuum.
	/// Normally you would call this right after initing a DatabaseQueue.
	///
	/// - Returns: true if database will be vacuumed.
	@discardableResult
	public func vacuumIfNeeded(daysBetweenVacuums: Int) -> Bool {
		let defaultsKey = "DatabaseQueue-LastVacuumDate-\(databasePath)"
		let minimumVacuumInterval = TimeInterval(daysBetweenVacuums * (60 * 60 * 24)) // Doesn’t have to be precise
		let now = Date()
		let cutoffDate = now - minimumVacuumInterval
		if let lastVacuumDate = UserDefaults.standard.object(forKey: defaultsKey) as? Date {
			if lastVacuumDate < cutoffDate {
				vacuum()
				UserDefaults.standard.set(now, forKey: defaultsKey)
				return true
			}
			return false
		}

		// Never vacuumed — almost certainly a new database.
		// Just set the LastVacuumDate pref to now and skip vacuuming.
		UserDefaults.standard.set(now, forKey: defaultsKey)
		return false
	}
}

private extension DatabaseQueue {

	func enqueueDatabaseCall(_ databaseBlock: DatabaseBlock) -> Int? {
		let lifecycleGeneration = state.withLock { state -> Int? in
			guard supportsSuspension else {
				return state.lifecycleGeneration
			}
			switch state.lifecycleState {
			case .active, .resuming:
				return state.lifecycleGeneration
			case .suspended:
				return nil
			}
		}
		if lifecycleGeneration == nil {
			Self.logger.debug("DatabaseQueue: skipped call because queue is suspended")
			databaseBlock(.failure(.isSuspended))
		}
		return lifecycleGeneration
	}

	private func _runInDatabase(_ state: inout State, _ databaseBlock: DatabaseBlock, _ useTransaction: Bool, _ lifecycleGeneration: Int) {
		precondition(!state.isCallingDatabase)

		state.isCallingDatabase = true
		defer {
			state.isCallingDatabase = false
		}

		autoreleasepool {
			guard case .active = state.lifecycleState,
				  state.lifecycleGeneration == lifecycleGeneration else {
				databaseBlock(.failure(.isSuspended))
				return
			}
			if useTransaction {
				state.database.beginTransaction()
			}
			databaseBlock(.success(state.database))
			if useTransaction {
				state.database.commit()
			}
		}
	}

	static func openDatabase(_ database: FMDatabase) {
		database.open()
		database.executeStatements("PRAGMA synchronous = 1;")
		database.setShouldCacheStatements(true)
	}
}
