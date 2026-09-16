import Foundation
import MapKit
import Security

/// No routing API key is stored in defaults, route exports, logs, or telemetry.
enum RoutingKeyStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "iFakeGPS") + ".routing",
         kSecAttrAccount as String: "openrouteservice"]
    }
    static func load() throws -> String {
        var query = Self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw RouteError.invalid("The routing API key could not be read from Keychain.")
        }
        return key
    }
    static func save(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw RouteError.invalid("The routing API key could not be removed.")
            }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw RouteError.invalid("The routing API key could not be saved.") }
    }
}

private final class NoRoutingRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward the Authorization header to a redirected endpoint.
        completionHandler(nil)
    }
}

@MainActor
struct RoadPlanningService {
    enum Mode: String, CaseIterable, Identifiable {
        case direct, appleWalking, osrmDriving, orsWalking, orsCycling, orsDriving
        var id: Self { self }
        var title: String {
            switch self {
            case .direct: "Straight segments (offline)"
            case .appleWalking: "Apple Maps walking"
            case .osrmDriving: "OSRM driving"
            case .orsWalking: "OpenRouteService walking"
            case .orsCycling: "OpenRouteService cycling"
            case .orsDriving: "OpenRouteService driving"
            }
        }
        var needsKey: Bool { rawValue.hasPrefix("ors") }
    }
    func plan(_ points: [RouteCoordinate], mode: Mode) async throws -> RouteGeometry {
        if mode == .direct { return try RouteGeometry(points: points) }
        guard (2...50).contains(points.count) else { throw RouteError.invalid("Online planning accepts 2 to 50 waypoints.") }
        try Task.checkCancellation()
        if mode == .appleWalking {
            var result: [RouteCoordinate] = []
            for (start, end) in zip(points, points.dropFirst()) {
                try Task.checkCancellation()
                let request = MKDirections.Request()
                request.source = MKMapItem(location: CLLocation(latitude: start.latitude, longitude: start.longitude), address: nil)
                request.destination = MKMapItem(location: CLLocation(latitude: end.latitude, longitude: end.longitude), address: nil)
                request.transportType = .walking
                let directions = MKDirections(request: request)
                let response = try await withTaskCancellationHandler {
                    try await directions.calculate()
                } onCancel: { directions.cancel() }
                try Task.checkCancellation()
                guard let route = response.routes.first else { throw RouteError.invalid("No walking route was found.") }
                result.append(start)
                result += try (0..<route.polyline.pointCount).map {
                    let c = route.polyline.points()[$0].coordinate
                    return try RouteCoordinate(latitude: c.latitude, longitude: c.longitude)
                }
                result.append(end)
                guard result.count <= RouteGeometry.maximumPoints else { throw RouteError.invalid("The planned route is too large.") }
            }
            return try RouteGeometry(points: result)
        }
        guard let provider = RoadProvider(rawValue: mode.rawValue) else { throw RouteError.invalid("Unknown route provider.") }
        let request = try RoutingHTTP.request(points: points, provider: provider, key: provider.isORS ? RoutingKeyStore.load() : "")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: NoRoutingRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw RouteError.invalid("Invalid routing response.") }
        let geometry = try RoutingHTTP.decode(data, status: response.statusCode, provider: provider)
        // Include the requested endpoints explicitly when a provider snaps to roads.
        return try RouteGeometry(points: [points[0]] + geometry.points + [points[points.count - 1]])
    }
}
