//
//  TimelineSortDirectionState.swift
//  NetNewsWire-iOS
//
//  Created by OpenAI on 6/23/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import Account

@MainActor final class TimelineSortDirectionState {
	private var sortDirections = [SidebarItemIdentifier: ComparisonResult]()

	func copy(from stateRestorationInfo: StateRestorationInfo) {
		sortDirections = stateRestorationInfo.sidebarItemTimelineSortDirections
	}

	func save() {
		AppDefaults.shared.sidebarItemTimelineSortDirections = cleanedUpSortDirections(sortDirections)
	}

	func sortDirection(for sidebarItemID: SidebarItemIdentifier, defaultSortDirection: ComparisonResult) -> ComparisonResult {
		sortDirections[sidebarItemID] ?? defaultSortDirection
	}

	func toggleSortDirection(for sidebarItemID: SidebarItemIdentifier, defaultSortDirection: ComparisonResult) {
		let currentSortDirection = sortDirection(for: sidebarItemID, defaultSortDirection: defaultSortDirection)
		sortDirections[sidebarItemID] = currentSortDirection == .orderedAscending ? .orderedDescending : .orderedAscending
		save()
	}
}

private extension TimelineSortDirectionState {

	func cleanedUpSortDirections(_ sortDirections: [SidebarItemIdentifier: ComparisonResult]) -> [SidebarItemIdentifier: ComparisonResult] {
		sortDirections.filter { sidebarItemID, _ in
			switch sidebarItemID {
			case .smartFeed:
				return true

			case .feed(let accountID, let feedID):
				guard let account = AccountManager.shared.existingAccount(accountID: accountID) else {
					return false
				}
				return account.existingFeed(withFeedID: feedID) != nil

			case .folder(let accountID, let folderName):
				guard let account = AccountManager.shared.existingAccount(accountID: accountID) else {
					return false
				}
				return account.existingFolder(withDisplayName: folderName) != nil
			}
		}
	}
}
