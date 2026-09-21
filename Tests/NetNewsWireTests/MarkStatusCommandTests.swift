//
//  MarkStatusCommandTests.swift
//  NetNewsWireTests
//

import Articles
import XCTest

@testable import NetNewsWire

@MainActor final class MarkStatusCommandTests: XCTestCase {

	func testStatusChangeHandlerRunsOnPerformUndoAndRedo() async {
		let undoManager = UndoManager()
		var flags = [Bool]()
		let performed = expectation(description: "performed")
		let undone = expectation(description: "undone")
		let redone = expectation(description: "redone")
		var expectations = [performed, undone, redone]

		let article = Article(accountID: UUID().uuidString,
							  articleID: UUID().uuidString,
							  feedID: UUID().uuidString,
							  uniqueID: UUID().uuidString,
							  title: "Test Article",
							  contentHTML: nil,
							  contentText: nil,
							  markdown: nil,
							  url: nil,
							  externalURL: nil,
							  summary: nil,
							  imageURL: nil,
							  datePublished: nil,
							  dateModified: nil,
							  authors: nil,
							  status: ArticleStatus(articleID: UUID().uuidString, read: false, dateArrived: Date()))

		guard let command = MarkStatusCommand(initialArticles: [article], statusKey: .read, flag: true, undoManager: undoManager, statusChangeHandler: { _, _, flag in
			flags.append(flag)
			expectations.removeFirst().fulfill()
		}) else {
			return XCTFail("Expected a command for an unread article")
		}

		command.perform()
		await fulfillment(of: [performed], timeout: 1.0)

		undoManager.undo()
		await fulfillment(of: [undone], timeout: 1.0)

		undoManager.redo()
		await fulfillment(of: [redone], timeout: 1.0)

		XCTAssertEqual(flags, [true, false, true])
	}
}
