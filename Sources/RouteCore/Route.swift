import Foundation

public enum RouteError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return NSLocalizedString(message, comment: "Route validation") }
    }
}

public struct RouteCoordinate: Codable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw RouteError.invalid("Coordinates must be finite and within latitude/longitude bounds.")
        }
        self.latitude = latitude
        self.longitude = longitude
    }

    enum CodingKeys: String, CodingKey { case latitude, longitude }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(latitude: values.decode(Double.self, forKey: .latitude),
                      longitude: values.decode(Double.self, forKey: .longitude))
    }
}

public struct SavedRoute: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let points: [RouteCoordinate]
    public let createdAt: Date

    public init(id: UUID = UUID(), name: String, points: [RouteCoordinate], createdAt: Date = Date()) throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.count <= 120, cleanName.unicodeScalars.allSatisfy({
            let value = $0.value
            return value == 9 || value == 10 || value == 13 ||
                (value >= 0x20 && value != 0xFFFE && value != 0xFFFF)
        }) else {
            throw RouteError.invalid("Route names must contain 1 to 120 characters.")
        }
        let geometry = try RouteGeometry(points: points)
        self.id = id
        self.name = cleanName
        self.points = geometry.points
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, name, points, createdAt }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id),
                      name: values.decode(String.self, forKey: .name),
                      points: values.decode([RouteCoordinate].self, forKey: .points),
                      createdAt: values.decode(Date.self, forKey: .createdAt))
    }

    public func renamed(_ name: String) throws -> Self {
        try Self(id: id, name: name, points: points, createdAt: createdAt)
    }
}

/// Validated route geometry, independent of MapKit and the device transport.
public struct RouteGeometry: Sendable {
    public static let maximumPoints = 50_000
    public let points: [RouteCoordinate]
    public let cumulativeDistances: [Double]
    public var length: Double { cumulativeDistances.last ?? 0 }
    private static let earthRadius = 6_371_000.0

    public init(points input: [RouteCoordinate]) throws {
        guard input.count <= Self.maximumPoints else {
            throw RouteError.invalid("A route may contain at most 50,000 points.")
        }
        var points: [RouteCoordinate] = []
        var distances = [0.0]
        for point in input {
            if let previous = points.last {
                let distance = Self.distance(previous, point)
                if distance < 0.001 { continue }
                guard distance < (.pi - 0.000001) * Self.earthRadius else {
                    throw RouteError.invalid("Antipodal points need an intermediate waypoint.")
                }
                distances.append((distances.last ?? 0) + distance)
            }
            points.append(point)
        }
        guard points.count >= 2 else {
            throw RouteError.invalid("A route needs at least two different points.")
        }
        self.points = points
        self.cumulativeDistances = distances
    }

    public static func distance(_ a: RouteCoordinate, _ b: RouteCoordinate) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1, dl = (b.longitude - a.longitude) * .pi / 180
        let h = pow(sin(dp / 2), 2) + cos(p1) * cos(p2) * pow(sin(dl / 2), 2)
        return 2 * earthRadius * asin(sqrt(min(1, max(0, h))))
    }

    public func coordinate(at distance: Double) -> RouteCoordinate {
        guard distance.isFinite, distance > 0 else { return points[0] }
        if distance >= length { return points[points.count - 1] }
        var lower = 0, upper = points.count - 1
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if cumulativeDistances[middle] < distance { lower = middle } else { upper = middle }
        }
        let fraction = (distance - cumulativeDistances[lower]) /
            (cumulativeDistances[upper] - cumulativeDistances[lower])
        let a = points[lower], b = points[upper]
        let angle = (cumulativeDistances[upper] - cumulativeDistances[lower]) / Self.earthRadius
        let aLat = a.latitude * .pi / 180, aLon = a.longitude * .pi / 180
        let bLat = b.latitude * .pi / 180, bLon = b.longitude * .pi / 180
        let wa = sin((1 - fraction) * angle) / sin(angle)
        let wb = sin(fraction * angle) / sin(angle)
        let x = wa * cos(aLat) * cos(aLon) + wb * cos(bLat) * cos(bLon)
        let y = wa * cos(aLat) * sin(aLon) + wb * cos(bLat) * sin(bLon)
        let z = wa * sin(aLat) + wb * sin(bLat)
        // atan2 returns bounded angles; the fallback guards numerical anomalies.
        return (try? RouteCoordinate(latitude: atan2(z, hypot(x, y)) * 180 / .pi,
                                     longitude: atan2(y, x) * 180 / .pi)) ?? a
    }
}

public struct PlaybackOptions: Equatable, Sendable {
    public let speedKMH: Double
    public let jitterPercent: Double
    public let pingPong: Bool

    public init(speedKMH: Double = 5, jitterPercent: Double = 0, pingPong: Bool = false) throws {
        guard speedKMH.isFinite, (0.1...50).contains(speedKMH) else {
            throw RouteError.invalid("Speed must be between 0.1 and 50 km/h.")
        }
        guard jitterPercent.isFinite, (0...50).contains(jitterPercent) else {
            throw RouteError.invalid("Speed variation must be between 0 and 50 percent.")
        }
        self.speedKMH = speedKMH
        self.jitterPercent = jitterPercent
        self.pingPong = pingPong
    }
}

/// Advance a COPY, submit its coordinate, then commit that copy only if the
/// transport accepted the update. Failed submissions must not consume distance.
public struct RoutePlayer: Sendable {
    public private(set) var geometry: RouteGeometry
    public var options: PlaybackOptions
    private var cycleDistance = 0.0

    public init(geometry: RouteGeometry, options: PlaybackOptions) {
        self.geometry = geometry
        self.options = options
    }
    /// Extend only the tail. Preserve both distance and return-leg direction.
    /// Validation is completed before mutating any state.
    public mutating func append(_ points: [RouteCoordinate]) throws {
        let extended = try RouteGeometry(points: geometry.points + points)
        guard extended.length > geometry.length else {
            throw RouteError.invalid("Append at least one different point after the route endpoint.")
        }
        let distance = distanceAlongRoute
        let returning = cycleDistance > geometry.length
        geometry = extended
        cycleDistance = returning ? 2 * extended.length - distance : distance
    }

    public var distanceAlongRoute: Double {
        cycleDistance <= geometry.length ? cycleDistance : 2 * geometry.length - cycleDistance
    }
    public var current: RouteCoordinate { geometry.coordinate(at: distanceAlongRoute) }
    public var hasArrived: Bool { !options.pingPong && cycleDistance >= geometry.length }
    public var progress: Double { distanceAlongRoute / geometry.length }

    @discardableResult
    public mutating func advance(seconds: Double, randomUnit: Double = 0.5) throws -> RouteCoordinate {
        guard seconds.isFinite, (0...5).contains(seconds) else {
            throw RouteError.invalid("Playback was interrupted; resume explicitly instead of skipping ahead.")
        }
        guard randomUnit.isFinite, (0...1).contains(randomUnit) else {
            throw RouteError.invalid("Random input must be between zero and one.")
        }
        let speed = options.speedKMH / 3.6 * (1 + (2 * randomUnit - 1) * options.jitterPercent / 100)
        if options.pingPong {
            cycleDistance = (cycleDistance + speed * seconds).truncatingRemainder(dividingBy: 2 * geometry.length)
        } else {
            // Also handles switching off looping on the return leg without teleporting.
            cycleDistance = min(geometry.length, distanceAlongRoute + speed * seconds)
        }
        return current
    }
}
