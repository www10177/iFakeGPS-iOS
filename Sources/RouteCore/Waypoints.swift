import Foundation

public struct NamedWaypoint: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let name: String
    public let coordinate: RouteCoordinate

    public init(id: UUID = UUID(), name: String, coordinate: RouteCoordinate) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RouteError.invalid("Names must contain 1 to 120 characters without control characters.")
        }
        self.id = id
        self.name = name
        self.coordinate = coordinate
    }
    private enum CodingKeys: String, CodingKey { case id, name, coordinate }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id),
                      name: values.decode(String.self, forKey: .name),
                      coordinate: values.decode(RouteCoordinate.self, forKey: .coordinate))
    }
}

/// An editable draft, separate from the immutable prefix of an active route.
public struct WaypointDraft: Sendable {
    public static let maximumWaypoints = 200
    public private(set) var points: [NamedWaypoint] = []
    public init() {}
    public mutating func add(_ point: NamedWaypoint) throws {
        guard points.count < Self.maximumWaypoints, !points.contains(where: { $0.id == point.id }) else {
            throw RouteError.invalid("A draft supports 200 waypoints with unique identifiers.")
        }
        points.append(point)
    }
    public mutating func replace(_ point: NamedWaypoint) throws {
        guard let index = points.firstIndex(where: { $0.id == point.id }) else {
            throw RouteError.invalid("This waypoint no longer exists.")
        }
        points[index] = point
    }
    public mutating func remove(ids: Set<UUID>) { points.removeAll { ids.contains($0.id) } }
    public mutating func move(from offsets: IndexSet, to destination: Int) throws {
        guard offsets.allSatisfy({ points.indices.contains($0) }), (0...points.count).contains(destination) else {
            throw RouteError.invalid("Invalid waypoint order.")
        }
        let moved = offsets.sorted().map { points[$0] }
        let insertion = destination - offsets.filter { $0 < destination }.count
        var remaining = points.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        remaining.insert(contentsOf: moved, at: insertion)
        points = remaining
    }
    public mutating func reverse() { points.reverse() }
    public mutating func clear() { points = [] }
    public func geometry(after anchor: RouteCoordinate? = nil) throws -> RouteGeometry {
        try RouteGeometry(points: (anchor.map { [$0] } ?? []) + points.map(\.coordinate))
    }
}
