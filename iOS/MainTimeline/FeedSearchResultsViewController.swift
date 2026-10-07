import UIKit
import Account

@MainActor final class FeedSearchResultsViewController: UITableViewController {
	weak var coordinator: SceneCoordinator?
	var onFeedSelected: ((Feed) -> Void)?

	private var feeds = [Feed]()

	func update(feeds: [Feed]) {
		self.feeds = feeds
		tableView.reloadData()
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		tableView.backgroundColor = .systemBackground
		tableView.keyboardDismissMode = .onDrag
	}

	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		feeds.count
	}

	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		let cell = tableView.dequeueReusableCell(withIdentifier: "FeedSearchResultCell")
			?? UITableViewCell(style: .subtitle, reuseIdentifier: "FeedSearchResultCell")
		let feed = feeds[indexPath.row]
		cell.textLabel?.text = feed.nameForDisplay
		cell.detailTextLabel?.text = feed.authors?.compactMap(\.name).sorted().joined(separator: ", ")
		cell.imageView?.image = IconImageCache.shared.imageForFeed(feed)?.image
		cell.accessoryType = .disclosureIndicator
		return cell
	}

	override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		tableView.deselectRow(at: indexPath, animated: true)
		onFeedSelected?(feeds[indexPath.row])
	}

	override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
		let feed = feeds[indexPath.row]
		return UIContextMenuConfiguration(identifier: feed.feedID as NSString, previewProvider: nil) { [weak self] _ in
			guard let self else { return nil }
			let goToFeed = UIAction(title: NSLocalizedString("Go to Feed", comment: "Go to Feed"), image: UIImage(systemName: "arrow.right")) { [weak self] _ in
				self?.onFeedSelected?(feed)
			}
			let inspector = UIAction(title: NSLocalizedString("Feed Info", comment: "Feed inspector"), image: UIImage(systemName: "info.circle")) { [weak self] _ in
				self?.coordinator?.showFeedInspector(for: feed)
			}
			let favoriteTitle = FavoriteFeedsController.shared.isFavorite(feed)
				? NSLocalizedString("Remove from Favorites", comment: "Command")
				: NSLocalizedString("Add to Favorites", comment: "Command")
			let favorite = UIAction(title: favoriteTitle, image: UIImage(systemName: "star")) { [weak self] _ in
				self?.coordinator?.toggleFavorite(for: feed)
			}
			let copyURL = UIAction(title: NSLocalizedString("Copy Feed URL", comment: "Command"), image: UIImage(systemName: "doc.on.doc")) { _ in
				UIPasteboard.general.string = feed.url
			}
			let openHome = feed.homePageURL.flatMap(URL.init(string:)).map { url in
				UIAction(title: NSLocalizedString("Open Home Page", comment: "Command"), image: UIImage(systemName: "safari")) { _ in
					UIApplication.shared.open(url)
				}
			}
			let markAll = UIAction(title: NSLocalizedString("Mark All as Read", comment: "Command"), image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
				Task { @MainActor in
					guard let account = feed.account,
						let articles = try? await account.fetchArticlesAsync(feedIDs: [feed.feedID]) else { return }
					self?.coordinator?.markAllAsRead(Array(articles))
				}
			}
			var actions: [UIMenuElement] = [goToFeed, inspector, favorite]
			if let openHome { actions.append(openHome) }
			actions.append(contentsOf: [copyURL, markAll])
			return UIMenu(title: "", children: actions)
		}
	}
}
