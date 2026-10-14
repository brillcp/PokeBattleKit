import Foundation

/// Simple JSON file cache in the app's Caches directory.
///
/// Files live in `Caches/PokeBattleKit/` and never expire; the OS may purge
/// them under storage pressure, in which case the next launch re-downloads.
/// Reads are best-effort: a missing or undecodable file (for example after
/// a model change) returns `nil`, so the caller refetches and overwrites it.
/// Writes are atomic, so a crash mid-save can't leave a truncated file.
struct DiskCache: Sendable {
    private let directory: URL

    init() {
        self.directory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PokeBattleKit", isDirectory: true)
    }

    func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func save<T: Encodable>(_ value: T, to filename: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }
}
