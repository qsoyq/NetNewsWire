//
//  VideoCacheDatabase.swift
//  NetNewsWire
//
//  Created by NetNewsWire on 2026/04/13.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import SQLite3
import os

nonisolated final class VideoCacheDatabase: Sendable {

	static let shared = VideoCacheDatabase()

	private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "VideoCacheDatabase")

	/// Maximum total cache size in bytes (500 MB).
	private static let maxTotalCacheSize: Int64 = 500 * 1024 * 1024

	private struct DatabasePointer: @unchecked Sendable {
		var pointer: OpaquePointer?
	}

	private let mutex = OSAllocatedUnfairLock<DatabasePointer>(initialState: DatabasePointer())

	private init() {
		mutex.withLock { wrapper in
			let path = Self.databasePath()
			if sqlite3_open(path, &wrapper.pointer) != SQLITE_OK {
				Self.logger.error("VideoCacheDatabase: Failed to open database at \(path)")
			} else if let db = wrapper.pointer {
				Self.createTable(db: db)
			}
		}
	}

	func cachedData(for url: String) -> (data: Data, contentType: String)? {
		mutex.withLock { wrapper in
			guard let db = wrapper.pointer else { return nil }

			var statement: OpaquePointer?
			let sql = "SELECT data, content_type FROM video_cache WHERE url = ? LIMIT 1"

			guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
				return nil
			}
			defer { sqlite3_finalize(statement) }

			sqlite3_bind_text(statement, 1, (url as NSString).utf8String, -1, nil)

			guard sqlite3_step(statement) == SQLITE_ROW else {
				return nil
			}

			guard let blobPointer = sqlite3_column_blob(statement, 0) else {
				return nil
			}
			let blobSize = sqlite3_column_bytes(statement, 0)
			let data = Data(bytes: blobPointer, count: Int(blobSize))

			let contentType: String
			if let cString = sqlite3_column_text(statement, 1) {
				contentType = String(cString: cString)
			} else {
				contentType = "application/octet-stream"
			}

			return (data, contentType)
		}
	}

	func cacheData(url: String, data: Data, contentType: String) {
		mutex.withLock { wrapper in
			guard let db = wrapper.pointer else { return }

			// Evict oldest entries if adding this item would exceed the total size limit
			Self.evictIfNeeded(db: db, incomingSize: data.count)

			var statement: OpaquePointer?
			let sql = "INSERT OR REPLACE INTO video_cache (url, data, content_type, cached_date) VALUES (?, ?, ?, ?)"

			guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
				return
			}
			defer { sqlite3_finalize(statement) }

			sqlite3_bind_text(statement, 1, (url as NSString).utf8String, -1, nil)
			_ = data.withUnsafeBytes { rawBuffer in
				sqlite3_bind_blob(statement, 2, rawBuffer.baseAddress, Int32(data.count), nil)
			}
			sqlite3_bind_text(statement, 3, (contentType as NSString).utf8String, -1, nil)
			sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)

			if sqlite3_step(statement) != SQLITE_DONE {
				Self.logger.error("VideoCacheDatabase: Failed to cache data for \(url)")
			}
		}
	}

	func clearAll() {
		mutex.withLock { wrapper in
			guard let db = wrapper.pointer else { return }
			sqlite3_exec(db, "DELETE FROM video_cache", nil, nil, nil)
			sqlite3_exec(db, "VACUUM", nil, nil, nil)
			Self.logger.info("VideoCacheDatabase: Cache cleared")
		}
	}

	/// Returns true if data for the given URL exists in the cache (without reading the blob).
	func hasCachedData(for url: String) -> Bool {
		mutex.withLock { wrapper in
			guard let db = wrapper.pointer else { return false }
			var stmt: OpaquePointer?
			guard sqlite3_prepare_v2(db, "SELECT 1 FROM video_cache WHERE url = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
				return false
			}
			defer { sqlite3_finalize(stmt) }
			sqlite3_bind_text(stmt, 1, (url as NSString).utf8String, -1, nil)
			return sqlite3_step(stmt) == SQLITE_ROW
		}
	}

	/// Returns total cache size in bytes.
	func totalCacheSize() -> Int64 {
		mutex.withLock { wrapper in
			guard let db = wrapper.pointer else { return 0 }
			return Self.queryTotalSize(db: db)
		}
	}
}

private extension VideoCacheDatabase {

	static func databasePath() -> String {
		let cacheDir: String
		if let url = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
			cacheDir = url.path
		} else {
			cacheDir = NSTemporaryDirectory()
		}
		return (cacheDir as NSString).appendingPathComponent("VideoCache.sqlite")
	}

	static func createTable(db: OpaquePointer) {
		let sql = """
		CREATE TABLE IF NOT EXISTS video_cache (
			url TEXT NOT NULL PRIMARY KEY,
			data BLOB NOT NULL,
			content_type TEXT,
			cached_date REAL NOT NULL
		)
		"""
		if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
			logger.error("VideoCacheDatabase: Failed to create table")
		}

		// Index for efficient LRU eviction
		let indexSQL = "CREATE INDEX IF NOT EXISTS idx_video_cache_date ON video_cache(cached_date)"
		sqlite3_exec(db, indexSQL, nil, nil, nil)
	}

	static func queryTotalSize(db: OpaquePointer) -> Int64 {
		var stmt: OpaquePointer?
		guard sqlite3_prepare_v2(db, "SELECT COALESCE(SUM(LENGTH(data)), 0) FROM video_cache", -1, &stmt, nil) == SQLITE_OK else {
			return 0
		}
		defer { sqlite3_finalize(stmt) }
		guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
		return sqlite3_column_int64(stmt, 0)
	}

	/// Evicts oldest cache entries until total size + incoming item fits within the limit.
	static func evictIfNeeded(db: OpaquePointer, incomingSize: Int) {
		let currentSize = queryTotalSize(db: db)

		guard currentSize + Int64(incomingSize) > maxTotalCacheSize else { return }

		// Target 80% of max so we don't evict on every single insert
		let targetSize = maxTotalCacheSize * 80 / 100

		var iterations = 0
		while iterations < 100 {
			iterations += 1

			let size = queryTotalSize(db: db)
			if size + Int64(incomingSize) <= targetSize {
				break
			}

			// Delete a batch of oldest entries
			let deleteSql = "DELETE FROM video_cache WHERE url IN (SELECT url FROM video_cache ORDER BY cached_date ASC LIMIT 10)"
			sqlite3_exec(db, deleteSql, nil, nil, nil)

			if sqlite3_changes(db) == 0 { break }
		}

		logger.info("VideoCacheDatabase: Evicted old entries to stay within size limit")
	}
}
