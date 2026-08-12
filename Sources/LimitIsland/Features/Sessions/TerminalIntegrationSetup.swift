import Foundation

enum TerminalIntegrationSetup {
    enum SetupError: LocalizedError {
        case couldNotCreateConfiguration
        var errorDescription: String? { "Could not update kitty's configuration." }
    }

    /// Enables kitty's documented socket-only remote control after the user has
    /// explicitly pressed Enable. Existing configuration is backed up first.
    static func enableKitty() throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/kitty", isDirectory: true)
        let config = directory.appendingPathComponent("kitty.conf")
        let managed = directory.appendingPathComponent("limit-island.conf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let includeLine = "include limit-island.conf"
        let existing = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        if !existing.components(separatedBy: .newlines).contains(includeLine) {
            if FileManager.default.fileExists(atPath: config.path) {
                let backup = directory.appendingPathComponent("kitty.conf.limit-island-backup")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try FileManager.default.copyItem(at: config, to: backup)
                }
            }
            let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
            try (existing + separator + "\n# Exact tab switching for Limit Island\n\(includeLine)\n")
                .write(to: config, atomically: true, encoding: .utf8)
        }
        try """
        # Managed by Limit Island. Remove the include from kitty.conf to disable.
        allow_remote_control socket-only
        listen_on unix:/tmp/limit-island-kitty
        """.write(to: managed, atomically: true, encoding: .utf8)
    }
}
