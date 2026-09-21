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
}

enum TimelineFetchMode: Equatable {
	case merge
	case replace
}
