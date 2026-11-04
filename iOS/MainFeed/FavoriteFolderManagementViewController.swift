import UIKit
import Account
import Images

/// Selection belongs to feed identities, so filtering and count updates cannot change it.
struct FavoriteFolderSelection {
	private(set) var selectedKeys = Set<FavoriteFeedKey>()

	mutating func toggle(_ key: FavoriteFeedKey) {
		if !selectedKeys.insert(key).inserted {
			selectedKeys.remove(key)
		}
	}

	mutating func toggleAll(in visibleKeys: Set<FavoriteFeedKey>) {
		guard !visibleKeys.isEmpty else {
			return
		}
		if visibleKeys.isSubset(of: selectedKeys) {
			selectedKeys.subtract(visibleKeys)
		} else {
			selectedKeys.formUnion(visibleKeys)
		}
	}

	mutating func retain(_ keys: Set<FavoriteFeedKey>) {
		selectedKeys.formIntersection(keys)
	}
}

@MainActor final class FavoriteFolderManagementViewController: UITableViewController, UISearchResultsUpdating {
	private let folder: FavoriteFeedsFolder
	private let favorites: FavoriteFeedsController
	private let search = UISearchController(searchResultsController: nil)
	private var feeds = [Feed]()
	private var visibleFeeds = [Feed]()
	private var selection = FavoriteFolderSelection()
	private var pendingUndo: FavoriteFolderBatchUndo?
	private var resultMessage: String?
	private var isApplying = false
	private lazy var selectAllButton = UIBarButtonItem(title: NSLocalizedString("Select All", comment: "Select all feeds"), style: .plain, target: self, action: #selector(toggleVisibleSelection))
	private lazy var moveButton = UIBarButtonItem(title: NSLocalizedString("Move to…", comment: "Move selected favorite feeds"), style: .plain, target: self, action: #selector(chooseDestination))
	private lazy var removeButton = UIBarButtonItem(title: "", style: .plain, target: self, action: #selector(confirmRemoval))

	init(folder: FavoriteFeedsFolder, favorites: FavoriteFeedsController = .shared) {
		self.folder = folder
		self.favorites = favorites
		super.init(style: .insetGrouped)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		title = folder.nameForDisplay
		navigationItem.largeTitleDisplayMode = .never
		navigationItem.rightBarButtonItem = selectAllButton
		search.searchResultsUpdater = self
		search.obscuresBackgroundDuringPresentation = false
		search.searchBar.placeholder = NSLocalizedString("Search Feeds", comment: "Search favorite folder feeds")
		navigationItem.searchController = search
		navigationItem.hidesSearchBarWhenScrolling = false
		definesPresentationContext = true
		tableView.rowHeight = UITableView.automaticDimension
		tableView.estimatedRowHeight = 64
		tableView.keyboardDismissMode = .onDrag
		removeButton.tintColor = .systemRed
		toolbarItems = [moveButton, .flexibleSpace(), removeButton]
		NotificationCenter.default.addObserver(self, selector: #selector(favoritesChanged), name: .FavoriteFeedsDidChange, object: favorites)
		reloadFeeds()
	}

	deinit {
		NotificationCenter.default.removeObserver(self)
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		navigationController?.setToolbarHidden(false, animated: animated)
		reloadFeeds()
	}

	@objc private func favoritesChanged() {
		guard !isApplying else {
			return
		}
		reloadFeeds()
	}

	private func reloadFeeds() {
		// Resolve current membership, including changes made in another window.
		let current = favorites.userFolders.first { $0.folderID == folder.folderID }
		feeds = current?.aliases.compactMap(\.feed) ?? []
		selection.retain(Set(feeds.map { FavoriteFeedKey(feed: $0) }))
		title = current?.nameForDisplay ?? folder.nameForDisplay
		filterFeeds()
	}

	func updateSearchResults(for searchController: UISearchController) {
		filterFeeds()
	}

	private func filterFeeds() {
		let query = (search.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		visibleFeeds = query.isEmpty ? feeds : feeds.filter {
			$0.nameForDisplay.localizedStandardContains(query) || $0.url.localizedStandardContains(query) || ($0.account?.nameForDisplay.localizedStandardContains(query) ?? false)
		}
		tableView.reloadData()
		updateControls()
	}

	private var visibleKeys: Set<FavoriteFeedKey> {
		Set(visibleFeeds.map { FavoriteFeedKey(feed: $0) })
	}

	private func updateControls() {
		let count = selection.selectedKeys.count
		let hiddenCount = selection.selectedKeys.subtracting(visibleKeys).count
		if let resultMessage, count == 0 {
			navigationItem.prompt = resultMessage
		} else if hiddenCount > 0 {
			navigationItem.prompt = String.localizedStringWithFormat(NSLocalizedString("%ld selected · %ld outside results", comment: "Selected feeds hidden by search"), count, hiddenCount)
		} else {
			navigationItem.prompt = String.localizedStringWithFormat(NSLocalizedString("%ld selected", comment: "Selected feed count"), count)
		}
		let allSelected = !visibleKeys.isEmpty && visibleKeys.isSubset(of: selection.selectedKeys)
		let searching = !(search.searchBar.text ?? "").isEmpty
		selectAllButton.title = allSelected
			? NSLocalizedString("Deselect All", comment: "Deselect visible feeds")
			: (searching ? NSLocalizedString("Select Results", comment: "Select all search results") : NSLocalizedString("Select All", comment: "Select all feeds"))
		selectAllButton.isEnabled = !visibleFeeds.isEmpty && !isApplying
		moveButton.isEnabled = count > 0 && !isApplying
		removeButton.isEnabled = count > 0 && !isApplying
		removeButton.title = String.localizedStringWithFormat(NSLocalizedString("Remove from %@", comment: "Remove feeds from current favorite folder"), folder.nameForDisplay)
		// Use the shorter action title on compact widths; the confirmation names the folder.
		if traitCollection.horizontalSizeClass == .compact {
			removeButton.title = NSLocalizedString("Remove from Folder", comment: "Remove selected folder membership")
		}
		var leftItems = [UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))]
		if pendingUndo != nil {
			leftItems.append(UIBarButtonItem(title: NSLocalizedString("Undo", comment: "Undo favorite organization"), style: .plain, target: self, action: #selector(undoLastOperation)))
		}
		navigationItem.leftBarButtonItems = leftItems
		if visibleFeeds.isEmpty {
			var empty = UIContentUnavailableConfiguration.empty()
			empty.image = UIImage(systemName: "folder")
			empty.text = feeds.isEmpty ? NSLocalizedString("This folder has no feeds", comment: "Empty favorite folder") : NSLocalizedString("No Matching Feeds", comment: "No feed search results")
			contentUnavailableConfiguration = empty
		} else {
			contentUnavailableConfiguration = nil
		}
	}

	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		visibleFeeds.count
	}

	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		let cell = tableView.dequeueReusableCell(withIdentifier: "ManagedFeed") ?? UITableViewCell(style: .default, reuseIdentifier: "ManagedFeed")
		let feed = visibleFeeds[indexPath.row]
		let selected = selection.selectedKeys.contains(FavoriteFeedKey(feed: feed))
		var content = cell.defaultContentConfiguration()
		content.text = feed.nameForDisplay
		content.textProperties.numberOfLines = 0
		content.secondaryTextProperties.numberOfLines = 2
		content.secondaryText = [feed.account?.nameForDisplay, URL(string: feed.url)?.host].compactMap { $0 }.joined(separator: " · ")
		content.image = IconImageCache.shared.imageForFeed(feed)?.image ?? UIImage(systemName: "globe")
		content.imageProperties.maximumSize = CGSize(width: 28, height: 28)
		cell.contentConfiguration = content
		let check = UIImageView(image: UIImage(systemName: selected ? "checkmark.circle.fill" : "circle"))
		check.tintColor = selected ? view.tintColor : .tertiaryLabel
		check.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24)
		check.sizeToFit()
		cell.accessoryView = check
		cell.accessibilityLabel = [content.text, content.secondaryText].compactMap { $0 }.joined(separator: ", ")
		cell.accessibilityValue = selected ? NSLocalizedString("Selected", comment: "Selected feed") : NSLocalizedString("Not selected", comment: "Unselected feed")
		cell.accessibilityTraits = selected ? [.button, .selected] : [.button]
		return cell
	}

	override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		selection.toggle(FavoriteFeedKey(feed: visibleFeeds[indexPath.row]))
		resultMessage = nil
		tableView.deselectRow(at: indexPath, animated: false)
		tableView.reloadRows(at: [indexPath], with: .none)
		updateControls()
	}

	@objc private func toggleVisibleSelection() {
		selection.toggleAll(in: visibleKeys)
		resultMessage = nil
		tableView.reloadData()
		updateControls()
	}

	@objc private func done() {
		dismiss(animated: true)
	}

	@objc private func chooseDestination() {
		guard !selection.selectedKeys.isEmpty else {
			return
		}
		search.searchBar.resignFirstResponder()
		let keys = selection.selectedKeys
		let picker = FavoriteFolderDestinationViewController(source: folder, count: keys.count, favorites: favorites)
		picker.completion = { [weak self] destination in
			guard let self else {
				return
			}
			self.navigationController?.popToViewController(self, animated: true)
			self.apply(keys, destination: destination)
		}
		navigationController?.pushViewController(picker, animated: true)
	}

	@objc private func confirmRemoval() {
		guard !selection.selectedKeys.isEmpty else {
			return
		}
		let keys = selection.selectedKeys
		let title = String.localizedStringWithFormat(NSLocalizedString("Remove %ld feeds from %@?", comment: "Confirm removing folder membership"), keys.count, folder.nameForDisplay)
		let message = NSLocalizedString("Feeds stay in Favorites. Feeds with no other folder appear in the default Feeds group. Subscriptions and articles are unchanged.", comment: "Explain removing from a favorite folder")
		let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
		alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel"), style: .cancel))
		alert.addAction(UIAlertAction(title: NSLocalizedString("Remove", comment: "Remove folder membership"), style: .destructive) { [weak self] _ in
			self?.apply(keys, destination: nil)
		})
		present(alert, animated: true)
	}

	private func apply(_ keys: Set<FavoriteFeedKey>, destination: FavoriteFeedsFolder?) {
		guard !isApplying else {
			return
		}
		isApplying = true
		updateControls()
		let result = favorites.organize(keys, from: folder, to: destination)
		isApplying = false
		if !result.processedKeys.isEmpty {
			pendingUndo = result.undo
		}
		selection.retain(result.failedKeys)
		let count = result.processedKeys.count
		if let destination {
			resultMessage = String.localizedStringWithFormat(NSLocalizedString("Moved %ld feeds to %@", comment: "Batch move result"), count, destination.nameForDisplay)
		} else {
			resultMessage = String.localizedStringWithFormat(NSLocalizedString("Removed %ld feeds from folder", comment: "Batch removal result"), count)
		}
		reloadFeeds()
		showFailures(result.failedKeys.count)
	}

	@objc private func undoLastOperation() {
		guard let pendingUndo else {
			return
		}
		isApplying = true
		let result = favorites.undoOrganization(pendingUndo)
		isApplying = false
		self.pendingUndo = nil
		resultMessage = String.localizedStringWithFormat(NSLocalizedString("Restored %ld feeds", comment: "Batch undo result"), result.processedKeys.count)
		reloadFeeds()
		showFailures(result.failedKeys.count)
	}

	private func showFailures(_ count: Int) {
		guard count > 0 else {
			return
		}
		let message = String.localizedStringWithFormat(NSLocalizedString("%ld feeds could not be updated. The feed or folder may have been removed. Available failed feeds remain selected so you can try again.", comment: "Batch organization partial failure"), count)
		let alert = UIAlertController(title: NSLocalizedString("Some Feeds Were Not Updated", comment: "Batch organization failure"), message: message, preferredStyle: .alert)
		alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "OK"), style: .default))
		present(alert, animated: true)
	}
}

@MainActor private final class FavoriteFolderDestinationViewController: UITableViewController {
	private let source: FavoriteFeedsFolder
	private let favorites: FavoriteFeedsController
	private var folders = [FavoriteFeedsFolder]()
	private var selectedID: String?
	var completion: ((FavoriteFeedsFolder) -> Void)?

	init(source: FavoriteFeedsFolder, count: Int, favorites: FavoriteFeedsController) {
		self.source = source
		self.favorites = favorites
		super.init(style: .insetGrouped)
		title = String.localizedStringWithFormat(NSLocalizedString("Move %ld Feeds", comment: "Choose batch move destination"), count)
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		navigationItem.rightBarButtonItem = UIBarButtonItem(title: NSLocalizedString("Move", comment: "Commit batch move"), style: .done, target: self, action: #selector(commitMove))
		reloadFolders()
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		navigationController?.setToolbarHidden(true, animated: animated)
		reloadFolders()
	}

	private func reloadFolders() {
		folders = favorites.userFolders.filter { $0.folderID != source.folderID }
		navigationItem.rightBarButtonItem?.isEnabled = folders.contains { $0.folderID == selectedID }
		tableView.reloadData()
	}

	override func numberOfSections(in tableView: UITableView) -> Int { 2 }

	override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		section == 0 ? folders.count : 1
	}

	override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
		guard section == 0 else {
			return nil
		}
		return String.localizedStringWithFormat(NSLocalizedString("Feeds will be removed from %@. Membership in other folders is kept.", comment: "Explain scoped favorite move"), source.nameForDisplay)
	}

	override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
		var content = cell.defaultContentConfiguration()
		if indexPath.section == 1 {
			content.text = NSLocalizedString("New Folder", comment: "Create move destination")
			content.image = UIImage(systemName: "folder.badge.plus")
		} else {
			let folder = folders[indexPath.row]
			content.text = folder.nameForDisplay
			content.textProperties.numberOfLines = 0
			content.image = UIImage(systemName: "folder")
			cell.accessoryType = selectedID == folder.folderID ? .checkmark : .none
		}
		cell.contentConfiguration = content
		return cell
	}

	override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		tableView.deselectRow(at: indexPath, animated: false)
		if indexPath.section == 1 {
			newFolder()
		} else {
			selectedID = folders[indexPath.row].folderID
			reloadFolders()
		}
	}

	private func newFolder() {
		let alert = UIAlertController(title: NSLocalizedString("New Folder", comment: "Create favorite folder"), message: nil, preferredStyle: .alert)
		alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel"), style: .cancel))
		let create = UIAlertAction(title: NSLocalizedString("Create", comment: "Create folder"), style: .default) { [weak self, weak alert] _ in
			guard let self, let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
				return
			}
			self.selectedID = self.favorites.createFolder(named: name).folderID
			self.reloadFolders()
		}
		create.isEnabled = false
		alert.addAction(create)
		alert.addTextField { [weak create] field in
			field.placeholder = NSLocalizedString("Folder Name", comment: "Favorite folder name")
			field.addAction(UIAction { [weak create] action in
				let text = (action.sender as? UITextField)?.text ?? ""
				create?.isEnabled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			}, for: .editingChanged)
		}
		present(alert, animated: true)
	}

	@objc private func commitMove() {
		guard let destination = favorites.userFolders.first(where: { $0.folderID == selectedID && $0.folderID != source.folderID }) else {
			reloadFolders()
			return
		}
		navigationItem.rightBarButtonItem?.isEnabled = false
		completion?(destination)
	}
}
