//
//  MainFeedCollectionViewController+Drop.swift
//  NetNewsWire-iOS
//
//  Created by Stuart Breckenridge on 14/07/2025.
//  Copyright © 2025 Ranchero Software. All rights reserved.
//

import UIKit
import WebKit
import Account
import Articles
import RSCore
import RSTree
import RSWeb
import SafariServices
import UniformTypeIdentifiers

extension MainFeedCollectionViewController: UICollectionViewDropDelegate {

	func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: any UICollectionViewDropCoordinator) {
		guard let dragItem = coordinator.items.first?.dragItem,
			  let dragNode = dragItem.localObject as? Node,
			  let destIndexPath = coordinator.destinationIndexPath else {
				  return
			  }

		if isFavoriteFeedsSection(destIndexPath) {
			performFavoriteDrop(dragNode: dragNode, destIndexPath: destIndexPath)
			return
		}

		guard let source = dragNode.parent?.representedObject as? Container else {
			return
		}

		let isFolderDrop: Bool = {
			if sidebarItemNode(for: destIndexPath)?.node.representedObject is Folder, let propCell = collectionView.cellForItem(at: destIndexPath) {
				return coordinator.session.location(in: propCell).y >= 0
			}
			return false
		}()

		// Based on the drop we have to determine a node to start looking for a parent container.
		let destNode: Node? = {

			if isFolderDrop {
				return sidebarItemNode(for: destIndexPath)?.node
			} else {
				if destIndexPath.row == 0 {
					return sidebarItemNode(for: IndexPath(row: 0, section: destIndexPath.section))?.node
				} else if destIndexPath.row > 0 {
					return sidebarItemNode(for: IndexPath(row: destIndexPath.row - 1, section: destIndexPath.section))?.node
				} else {
					return nil
				}
			}

		}()

		// Now we start looking for the parent container
		let destinationContainer: Container? = {
			if let container = (destNode?.representedObject as? Container) ?? (destNode?.parent?.representedObject as? Container) {
				return container
			} else {
				// If we got here, we are trying to drop on an empty section header.  Go and find the Account for this section
				let sectionID = currentSidebarSnapshot.sectionIdentifiers[destIndexPath.section]
				return AccountManager.shared.existingAccount(accountID: sectionID)
			}
		}()

		guard let destination = destinationContainer, let feed = dragNode.representedObject as? Feed else { return }

		if source.account == destination.account {
			moveFeedInAccount(feed: feed, sourceContainer: source, destinationContainer: destination)
		} else {
			copyFeedBetweenAccounts(feed: feed, destinationContainer: destination)
		}
	}

	func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: any UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {

		guard let destIndexPath = destinationIndexPath, collectionView.hasActiveDrag else {
			return UICollectionViewDropProposal(operation: .forbidden)
		}
		if isFavoriteFeedsSection(destIndexPath) {
			return favoriteDropProposal(session: session, destIndexPath: destIndexPath)
		}
		guard isAccountSection(destIndexPath) else {
			return UICollectionViewDropProposal(operation: .forbidden)
		}

		guard let destFeed = sidebarItemNode(for: destIndexPath)?.node.representedObject as? SidebarItem,
			  let destAccount = destFeed.account,
			  let destCell = collectionView.cellForItem(at: destIndexPath) else {
				  return UICollectionViewDropProposal(operation: .forbidden)
			  }

		// Validate account specific behaviors...
		if destAccount.behaviors.contains(.disallowFeedInMultipleFolders),
		   let sourceNode = session.localDragSession?.items.first?.localObject as? Node,
		   let sourceFeed = sourceNode.representedObject as? Feed,
		   sourceFeed.account?.accountID != destAccount.accountID && destAccount.hasFeed(withURL: sourceFeed.url) {
			return UICollectionViewDropProposal(operation: .forbidden)
		}

		// Cross-account drops copy the feed; same-account drops move it.
		let sourceFeed = (session.localDragSession?.items.first?.localObject as? Node)?.representedObject as? Feed
		let operation: UIDropOperation = (sourceFeed?.account?.accountID != destAccount.accountID) ? .copy : .move

		// Determine the correct drop proposal
		if destFeed is Folder {
			if session.location(in: destCell).y >= 0 {
				return UICollectionViewDropProposal(operation: operation, intent: .insertIntoDestinationIndexPath)
			} else {
				return UICollectionViewDropProposal(operation: operation, intent: .unspecified)
			}
		} else {
			return UICollectionViewDropProposal(operation: operation, intent: .insertAtDestinationIndexPath)
		}
	}

	func collectionView(_ collectionView: UICollectionView, canHandle session: any UIDropSession) -> Bool {
		return session.localDragSession != nil
	}

	func collectionView(_ collectionView: UICollectionView, dropSessionDidEnd session: UIDropSession) {
	}

	func moveFeedInAccount(feed: Feed, sourceContainer: Container, destinationContainer: Container) {
		guard sourceContainer !== destinationContainer else {
			return
		}
		guard let account = sourceContainer.account else {
			return
		}

		BatchUpdate.shared.start()
		account.moveFeed(feed, from: sourceContainer, to: destinationContainer) { result in
			BatchUpdate.shared.end()
			switch result {
			case .success:
				break
			case .failure(let error):
				self.presentError(error)
			}
		}
	}

	func copyFeedBetweenAccounts(feed: Feed, destinationContainer: Container) {
		guard let destinationAccount = destinationContainer.account else {
			return
		}

		if let existingFeed = destinationAccount.existingFeed(withURL: feed.url) {

			BatchUpdate.shared.start()
			destinationAccount.addFeed(existingFeed, to: destinationContainer) { result in
				BatchUpdate.shared.end()
				switch result {
				case .success:
					break
				case .failure(let error):
					self.presentError(error)
				}
			}

		} else {

			BatchUpdate.shared.start()
			destinationAccount.createFeed(url: feed.url, name: feed.editedName, container: destinationContainer, validateFeed: false) { result in
				BatchUpdate.shared.end()
				switch result {
				case .success:
					break
				case .failure(let error):
					self.presentError(error)
				}
			}

		}
	}

	func favoriteDropProposal(session: any UIDropSession, destIndexPath: IndexPath) -> UICollectionViewDropProposal {
		guard let sourceNode = session.localDragSession?.items.first?.localObject as? Node,
			  let destObject = sidebarItemNode(for: destIndexPath)?.node.representedObject else {
			return UICollectionViewDropProposal(operation: .forbidden)
		}

		let isAlias = sourceNode.representedObject is FavoriteFeedAlias
		let isFeed = sourceNode.representedObject is Feed
		guard isAlias || isFeed else {
			return UICollectionViewDropProposal(operation: .forbidden)
		}

		if destObject is FavoriteFeedsAllFeed {
			if isFeed {
				return UICollectionViewDropProposal(operation: .copy, intent: .insertAtDestinationIndexPath)
			}
			return UICollectionViewDropProposal(operation: .forbidden)
		}

		let destination = favoriteDestinationFolder(at: destIndexPath)
		let operation: UIDropOperation = (isFeed || destination != nil) ? .copy : .move
		if destObject is FavoriteFeedsFolder {
			return UICollectionViewDropProposal(operation: operation, intent: .insertIntoDestinationIndexPath)
		}
		if destObject is FavoriteFeedAlias {
			return UICollectionViewDropProposal(operation: operation, intent: .insertAtDestinationIndexPath)
		}
		return UICollectionViewDropProposal(operation: .forbidden)
	}

	func favoriteDestinationFolder(at destIndexPath: IndexPath) -> FavoriteFeedsFolder? {
		let destNode = sidebarItemNode(for: destIndexPath)?.node
		if let folder = destNode?.representedObject as? FavoriteFeedsFolder {
			return folder.isUserFolder ? folder : nil
		}
		if destNode?.representedObject is FavoriteFeedAlias,
		   let folder = destNode?.parent?.representedObject as? FavoriteFeedsFolder {
			return folder.isUserFolder ? folder : nil
		}
		return nil
	}

	func performFavoriteDrop(dragNode: Node, destIndexPath: IndexPath) {
		let destObject = sidebarItemNode(for: destIndexPath)?.node.representedObject
		let destination = favoriteDestinationFolder(at: destIndexPath)
		let discloseFolder = destObject is FavoriteFeedsFolder || destObject is FavoriteFeedAlias

		if let alias = dragNode.representedObject as? FavoriteFeedAlias {
			if destination != nil || destObject is FavoriteFeedsFolder {
				coordinator.moveFavorite(alias, to: destination, discloseFolder: discloseFolder)
			}
			return
		}

		if let feed = dragNode.representedObject as? Feed {
			coordinator.favorite(feed, to: destination, discloseFolder: discloseFolder)
		}
	}

}
