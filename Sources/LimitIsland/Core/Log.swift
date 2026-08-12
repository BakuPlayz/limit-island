import os

/// Named loggers so a failed read leaves a trace. Everything here used to be
/// swallowed by `try?`, which made an expired token, an offline machine and a
/// provider outage look identical from the outside.
///
/// Watch with: `log stream --predicate 'subsystem == "com.limitisland"'`
enum Log {
    static let usage = Logger(subsystem: "com.limitisland", category: "usage")
    static let auth = Logger(subsystem: "com.limitisland", category: "auth")
    static let window = Logger(subsystem: "com.limitisland", category: "window")
    static let hooks = Logger(subsystem: "com.limitisland", category: "hooks")
}
