import Foundation
import CleanerCore

public actor CleanHistoryStore {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.fileURL = support
                .appendingPathComponent("CleanerMac", isDirectory: true)
                .appendingPathComponent("trash-history.json")
        }
    }

    public func loadEntries() -> [TrashHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([TrashHistoryEntry].self, from: data) else {
            return []
        }
        return entries.sorted { $0.trashedAt > $1.trashedAt }
    }

    public func append(_ newEntries: [TrashHistoryEntry]) {
        guard !newEntries.isEmpty else { return }
        var combined = loadEntries()
        combined.insert(contentsOf: newEntries, at: 0)
        save(Array(combined.prefix(500)))
    }

    public func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let remaining = loadEntries().filter { !ids.contains($0.id) }
        save(remaining)
    }

    private func save(_ entries: [TrashHistoryEntry]) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

