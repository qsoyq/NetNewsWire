//
//  ContainerIdentifier.swift
//  Account
//
//  Created by Maurice Parker on 11/24/19.
//  Copyright © 2019 Ranchero Software, LLC. All rights reserved.
//

import Foundation

@MainActor public protocol ContainerIdentifiable {
	var containerID: ContainerIdentifier? { get }
}

public enum ContainerIdentifier: Hashable, Equatable, Sendable {
	case smartFeedController
	case favoriteFeedsController
	case favoriteFeedsFolder(String) // folderID
	case account(String) // accountID
	case folder(String, String) // accountID, folderName

	public var userInfo: [AnyHashable: AnyHashable] {
		switch self {
		case .smartFeedController:
			return [
				"type": "smartFeedController"
			]
		case .favoriteFeedsController:
			return [
				"type": "favoriteFeedsController"
			]
		case .favoriteFeedsFolder(let folderID):
			return [
				"type": "favoriteFeedsFolder",
				"folderID": folderID
			]
		case .account(let accountID):
			return [
				"type": "account",
				"accountID": accountID
			]
		case .folder(let accountID, let folderName):
			return [
				"type": "folder",
				"accountID": accountID,
				"folderName": folderName
			]
		}
	}

	public init?(userInfo: [AnyHashable: AnyHashable]) {
		guard let type = userInfo["type"] as? String else { return nil }

		switch type {
		case "smartFeedController":
			self = ContainerIdentifier.smartFeedController
		case "favoriteFeedsController":
			self = ContainerIdentifier.favoriteFeedsController
		case "favoriteFeedsFolder":
			guard let folderID = userInfo["folderID"] as? String else { return nil }
			self = ContainerIdentifier.favoriteFeedsFolder(folderID)
		case "account":
			guard let accountID = userInfo["accountID"] as? String else { return nil }
			self = ContainerIdentifier.account(accountID)
		case "folder":
			guard let accountID = userInfo["accountID"] as? String, let folderName = userInfo["folderName"] as? String else { return nil }
			self = ContainerIdentifier.folder(accountID, folderName)
		default:
			return nil
		}
	}

}

extension ContainerIdentifier: Encodable {
	enum CodingKeys: CodingKey {
		case type
		case accountID
		case folderName
		case folderID
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .smartFeedController:
			try container.encode("smartFeedController", forKey: .type)
		case .favoriteFeedsController:
			try container.encode("favoriteFeedsController", forKey: .type)
		case .favoriteFeedsFolder(let folderID):
			try container.encode("favoriteFeedsFolder", forKey: .type)
			try container.encode(folderID, forKey: .folderID)
		case .account(let accountID):
			try container.encode("account", forKey: .type)
			try container.encode(accountID, forKey: .accountID)
		case .folder(let accountID, let folderName):
			try container.encode("folder", forKey: .type)
			try container.encode(accountID, forKey: .accountID)
			try container.encode(folderName, forKey: .folderName)
		}
	}
}

extension ContainerIdentifier: Decodable {

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let type =  try container.decode(String.self, forKey: .type)

		switch type {
		case "smartFeedController":
			self = .smartFeedController
		case "favoriteFeedsController":
			self = .favoriteFeedsController
		case "favoriteFeedsFolder":
			let folderID = try container.decode(String.self, forKey: .folderID)
			self = .favoriteFeedsFolder(folderID)
		case "account":
			let accountID =  try container.decode(String.self, forKey: .accountID)
			self = .account(accountID)
		default:
			let accountID =  try container.decode(String.self, forKey: .accountID)
			let folderName =  try container.decode(String.self, forKey: .folderName)
			self = .folder(accountID, folderName)
		}
	}
}
