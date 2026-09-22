//
//  ErrorLogView.swift
//  NetNewsWire-iOS
//
//  Created by Brent Simmons on 3/13/26.
//

import SwiftUI
import UIKit
import Account
import ErrorLog

struct ErrorLogView: View {

	private static let pageSize = 200

	@State private var entries = [ErrorLogEntry]()
	@State private var totalCount = 0
	@State private var isLoading = false
	@State private var isExporting = false
	@State private var shareURL: URL?
	@State private var isShareSheetPresented = false
	@State private var exportError: String?

	var body: some View {
		Group {
			if isLoading && entries.isEmpty {
				ProgressView("Loading Error Log…")
			} else if entries.isEmpty {
				ContentUnavailableView("No Errors Logged", systemImage: "checkmark.circle")
			} else {
				List {
					Section {
						privacyWarning
					}
					Section {
						ForEach(entries, id: \.id) { entry in
							ErrorLogEntryRow(entry: entry)
						}
						if entries.count < totalCount {
							Button {
								Task { await loadEarlierEntries() }
							} label: {
								HStack {
									Spacer()
									if isLoading {
										ProgressView()
									} else {
										Text("Load Earlier Entries")
									}
									Spacer()
								}
							}
							.disabled(isLoading)
						}
					} header: {
						Text("Showing \(entries.count) of \(totalCount), newest first")
					}
				}
				.listStyle(.plain)
			}
		}
		.navigationTitle("Error Log")
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				Button("Refresh", systemImage: "arrow.clockwise") {
					Task { await reloadLatestEntries() }
				}
				.disabled(isLoading || isExporting)
			}
			ToolbarItem(placement: .topBarTrailing) {
				Button("Clear", role: .destructive) {
					Task { await clearEntries() }
				}
				.disabled(entries.isEmpty || isLoading || isExporting)
			}
			if #available(iOS 26.0, *) {
				ToolbarSpacer(.fixed, placement: .topBarTrailing)
			}
			ToolbarItem(placement: .topBarTrailing) {
				Button("Copy Recent") {
					Task { await copyLoadedEntries() }
				}
				.disabled(entries.isEmpty || isExporting)
			}
			ToolbarItem(placement: .topBarTrailing) {
				Button {
					Task { await exportDiagnostics() }
				} label: {
					if isExporting {
						ProgressView()
					} else {
						Label("Share Diagnostics", systemImage: "square.and.arrow.up")
					}
				}
				.disabled(entries.isEmpty || isExporting)
			}
		}
		.task {
			await reloadLatestEntries()
		}
		.sheet(isPresented: $isShareSheetPresented) {
			if let shareURL {
				ActivityViewController(activityItems: [shareURL])
			}
		}
		.alert("Unable to Export Diagnostics", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
			Button("OK", role: .cancel) { exportError = nil }
		} message: {
			Text(exportError ?? "")
		}
	}

	private var privacyWarning: some View {
		Text("Errors may contain feed URLs and other information you may not want to share publicly.")
			.font(.footnote)
			.foregroundStyle(.secondary)
	}
}

// MARK: - Actions

private extension ErrorLogView {

	func reloadLatestEntries() async {
		guard !isLoading else { return }
		isLoading = true
		async let latestEntries = AccountManager.shared.errorLogDatabase.entries(limit: Self.pageSize)
		async let count = AccountManager.shared.errorLogDatabase.entryCount()
		entries = await latestEntries
		totalCount = await count
		isLoading = false
	}

	func loadEarlierEntries() async {
		guard !isLoading, let beforeID = entries.last?.id else { return }
		isLoading = true
		let olderEntries = await AccountManager.shared.errorLogDatabase.entries(limit: Self.pageSize, beforeID: beforeID)
		entries.append(contentsOf: olderEntries)
		isLoading = false
	}

	func clearEntries() async {
		guard !isLoading else { return }
		isLoading = true
		await AccountManager.shared.errorLogDatabase.clearEntries()
		entries = []
		totalCount = 0
		isLoading = false
	}

	func exportDiagnostics() async {
		guard !isExporting else { return }
		isExporting = true
		defer { isExporting = false }
		let database = AccountManager.shared.errorLogDatabase
		let header = diagnosticsHeader()
		do {
			shareURL = try await Task.detached(priority: .userInitiated) {
				let allEntries = await database.allEntries()
				return try ErrorLogTextFormatter.writeDiagnosticsFile(entries: allEntries, header: header)
			}.value
			isShareSheetPresented = true
		} catch {
			exportError = error.localizedDescription
		}
	}

	func copyLoadedEntries() async {
		guard !isExporting else { return }
		isExporting = true
		defer { isExporting = false }
		let loadedEntries = entries
		let header = diagnosticsHeader()
		UIPasteboard.general.string = await Task.detached(priority: .userInitiated) {
			ErrorLogTextFormatter.diagnosticsText(entries: loadedEntries, header: header)
		}.value
	}
}

// MARK: - Rows

private struct ErrorLogEntryRow: View {

	let entry: ErrorLogEntry

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("[\(ErrorLogTextFormatter.timestamp(entry.date))] [\(entry.level.name)]")
				.font(.caption.monospaced())
				.foregroundStyle(.secondary)
			Text(sourceText)
				.font(.body.monospaced().weight(.medium))
				.foregroundStyle(color)
			Text(entry.errorMessage)
				.font(.body.monospaced())
				.textSelection(.enabled)
			if !entry.functionName.isEmpty {
				Text("\(entry.fileName):\(entry.functionName):\(entry.lineNumber)")
					.font(.caption2.monospaced())
					.foregroundStyle(.tertiary)
			}
		}
		.padding(.vertical, 4)
	}

	private var sourceText: String {
		entry.operation.isEmpty ? entry.sourceName : "\(entry.sourceName) — \(entry.operation)"
	}

	private var color: Color {
		guard let type = AccountType(rawValue: entry.sourceID) else {
			return .secondary
		}
		switch type {
		case .onMyMac: return Color.secondary
		case .cloudKit: return Color.purple
		case .feedly: return Color.green
		case .feedbin: return Color.blue
		case .newsBlur: return Color.orange
		case .freshRSS: return Color.teal
		case .inoreader: return Color.brown
		case .bazQux: return Color.indigo
		case .theOldReader: return Color.pink
		}
	}
}

// MARK: - Export

private extension ErrorLogView {

	@MainActor func diagnosticsHeader() -> String {
		let info = Bundle.main.infoDictionary ?? [:]
		let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
		let build = info["CFBundleVersion"] as? String ?? "unknown"
		let commit = info["NNWGitCommit"] as? String ?? "unknown"
		return """
		NetNewsWire Diagnostics
		Generated: \(ErrorLogTextFormatter.timestamp(Date()))
		Version: \(version) (\(build))
		Commit: \(commit)
		Device: \(UIDevice.current.model)
		System: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
		"""
	}
}

private struct ActivityViewController: UIViewControllerRepresentable {

	let activityItems: [Any]

	func makeUIViewController(context: Context) -> UIActivityViewController {
		UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
	}

	func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
	}
}
