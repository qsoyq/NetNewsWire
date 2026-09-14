//
//  LogLevelView.swift
//  NetNewsWire-iOS
//

import SwiftUI
import ErrorLog

struct LogLevelView: View {

	@Environment(\.dismiss) private var dismiss
	@State private var selectedLevel = AppDefaults.shared.errorLogLevel

	var body: some View {
		List(ErrorLogLevel.allCases, id: \.rawValue) { level in
			Button {
				selectedLevel = level
				AppDefaults.shared.errorLogLevel = level
				dismiss()
			} label: {
				HStack {
					Text(level.name)
					Spacer()
					if selectedLevel == level {
						Image(systemName: "checkmark")
							.foregroundStyle(.tint)
					}
				}
			}
		}
		.navigationTitle("Log Level")
	}
}
