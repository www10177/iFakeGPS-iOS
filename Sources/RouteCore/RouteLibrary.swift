import Foundation

/// Atomic, versioned persistence. Callers serialize access (the iOS model uses MainActor).
/// Corrupt or newer libraries throw; they must never be replaced with an empty library.
public enum RouteLibrary {
    private struct Envelope: Codable {
        let version: Int
        let routes: [SavedRoute]
    }
    public static let maximumBytes = 20 * 1024 * 1024

    public static func load(from url: URL) throws -> [SavedRoute] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw RouteError.invalid("Route library exceeds 20 MiB.") }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw RouteError.invalid("Route library exceeds 20 MiB.") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.version == 1 else { throw RouteError.invalid("Unsupported route library version.") }
        try validate(envelope.routes)
        return envelope.routes
    }

    public static func save(_ routes: [SavedRoute], to url: URL) throws {
        try validate(routes)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(version: 1, routes: routes))
        guard data.count <= maximumBytes else { throw RouteError.invalid("Route library exceeds 20 MiB.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func validate(_ routes: [SavedRoute]) throws {
        guard routes.count <= 200, Set(routes.map(\.id)).count == routes.count,
              routes.reduce(0, { $0 + $1.points.count }) <= 200_000 else {
            throw RouteError.invalid("Library limit is 200 routes / 200,000 points; route IDs must be unique.")
        }
    }
}
