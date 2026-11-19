import Foundation

/// Codable JSON in Application Support, written with .atomic, with a version
/// field on the stored records. No SwiftData, no Core Data: JSON is simpler
/// to inspect, migrate, and recover. The previous good file is kept as a
/// backup; if the current file will not decode, the backup is loaded and the
/// bad file is set aside, never overwritten with an empty file.
struct LocalStore<T: Codable> {
    let fileName: String

    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.final-whistle", isDirectory: true)
    }

    private var fileURL: URL { directory.appendingPathComponent(fileName) }
    private var backupURL: URL { directory.appendingPathComponent(fileName + ".bak") }
    private var corruptURL: URL { directory.appendingPathComponent(fileName + ".corrupt") }

    func load() throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            // Try the backup before giving up.
            if let backup = try? Data(contentsOf: backupURL),
               let value = try? JSONDecoder().decode(T.self, from: backup) {
                return value
            }
            // Set the unreadable file aside for inspection; do not delete it
            // and do not overwrite it with an empty file.
            try? FileManager.default.moveItem(at: fileURL, to: corruptURL)
            throw error
        }
    }

    func save(_ value: T) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // Keep the previous good file as the backup.
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: fileURL, to: backupURL)
        }
        try data.write(to: fileURL, options: [.atomic])
    }

    func delete() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: backupURL)
    }
}
