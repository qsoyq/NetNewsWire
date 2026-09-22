import Foundation

public enum ErrorLogTextFormatter {
	public static func timestamp(_ date: Date) -> String {
		date.ISO8601Format(.init(includingFractionalSeconds: true))
	}

	public static func diagnosticsText(entries: [ErrorLogEntry], header: String) -> String {
		header + "\n\n" + entries.map(entryText).joined(separator: "\n\n") + "\n"
	}

	public static func writeDiagnosticsFile(entries: [ErrorLogEntry], header: String) throws -> URL {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NNW-Diagnostics-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let url = directory.appendingPathComponent("NetNewsWire-Diagnostics.txt")
		try diagnosticsText(entries: entries, header: header).write(to: url, atomically: true, encoding: .utf8)
		return url
	}

	private static func entryText(_ entry: ErrorLogEntry) -> String {
		let source = entry.operation.isEmpty ? entry.sourceName : "\(entry.sourceName) \u{2014} \(entry.operation)"
		let location = entry.functionName.isEmpty ? "" : " (\(entry.fileName):\(entry.functionName):\(entry.lineNumber))"
		return "[\(timestamp(entry.date))] [\(entry.level.name)] \(source): \(entry.errorMessage)\(location)"
	}
}
