//
//  MainFeedCollectionViewController+Drag.swift
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

extension MainFeedCollectionViewController: UICollectionViewDragDelegate {
	func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: any UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
		guard let node = dataSource.itemIdentifier(for: indexPath)?.node else {
			return [UIDragItem]()
		}

		let urlString: String
		if let feed = node.representedObject as? Feed {
			urlString = feed.url
		} else if let alias = node.representedObject as? FavoriteFeedAlias, let feed = alias.feed {
			urlString = feed.url
		} else {
			return [UIDragItem]()
		}

		let data = urlString.data(using: .utf8)
		let itemProvider = NSItemProvider()

		itemProvider.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .ownProcess) { completion in
			Task { @MainActor in
				completion(data, nil)
			}
			return nil
		}

		let dragItem = UIDragItem(itemProvider: itemProvider)
		dragItem.localObject = node
		return [dragItem]
	}
}
