//
//  TimelineRefreshReason.swift
//  NetNewsWire
//

enum TimelineRefreshReason: Equatable {
	case foreground
	case feedSelection

	var fetchMode: TimelineFetchMode {
		switch self {
		case .foreground:
			return .merge
		case .feedSelection:
			return .replace
		}
	}

	var emptiesTimelineBeforeFetch: Bool {
		switch self {
		case .foreground:
			return false
		case .feedSelection:
			return true
		}
	}
}

enum TimelineFetchMode: Equatable {
	case merge
	case replace
}
