import Foundation
import os

/// The last 50 events, for "Copy diagnostics". Events name what happened,
/// never the text of a line or a prompt.
public actor EventLog {
    private var events: [String] = []
    private let log = Logger(subsystem: "com.kobi.app", category: "events")
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public init() {}

    public func add(_ event: String) {
        log.info("\(event, privacy: .public)")
        events.append("\(stamp.string(from: Date())) \(event)")
        if events.count > 50 { events.removeFirst(events.count - 50) }
    }

    public var recent: [String] { events }
}
