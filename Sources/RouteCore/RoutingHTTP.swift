import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RoadProvider: String, CaseIterable, Sendable {
    case osrmDriving, orsWalking, orsCycling, orsDriving
    public var isORS: Bool { self != .osrmDriving }
    public var profile: String {
        switch self {
        case .osrmDriving: "driving"
        case .orsWalking: "foot-walking"
        case .orsCycling: "cycling-regular"
        case .orsDriving: "driving-car"
        }
    }
}

/// Request and response validation is testable without sending private coordinates.
public enum RoutingHTTP {
    public static func request(points: [RouteCoordinate], provider: RoadProvider, key: String = "") throws -> URLRequest {
        guard (2...50).contains(points.count) else {
            throw RouteError.invalid("Online road planning accepts 2 to 50 waypoints per request.")
        }
        var request: URLRequest
        if provider.isORS {
            let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, token.utf8.count <= 4096,
                  !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw RouteError.invalid("Enter a valid OpenRouteService API key.")
            }
            guard let url = URL(string: "https://api.openrouteservice.org/v2/directions/\(provider.profile)/geojson") else {
                throw RouteError.invalid("Invalid routing endpoint.")
            }
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["coordinates": points.map { [$0.longitude, $0.latitude] }])
        } else {
            let coordinates = points.map { "\($0.longitude),\($0.latitude)" }.joined(separator: ";")
            guard let url = URL(string: "https://router.project-osrm.org/route/v1/driving/\(coordinates)?overview=full&geometries=geojson") else {
                throw RouteError.invalid("Invalid routing endpoint.")
            }
            request = URLRequest(url: url)
        }
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json, application/geo+json", forHTTPHeaderField: "Accept")
        return request
    }

    public static func decode(_ data: Data, status: Int, provider: RoadProvider) throws -> RouteGeometry {
        guard status == 200 else {
            switch status {
            case 401, 403: throw RouteError.invalid("The routing service rejected the API key.")
            case 429: throw RouteError.invalid("The routing service rate limit was reached. Try again later.")
            default: throw RouteError.invalid("The routing service could not produce a route.")
            }
        }
        guard data.count <= 10 * 1024 * 1024 else { throw RouteError.invalid("The routing response is too large.") }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RouteError.invalid("Invalid routing response.")
        }
        let geometry: [String: Any]?
        if provider.isORS {
            geometry = (root["features"] as? [[String: Any]])?.first?["geometry"] as? [String: Any]
        } else {
            guard root["code"] as? String == "Ok" else { throw RouteError.invalid("No road route was found.") }
            geometry = (root["routes"] as? [[String: Any]])?.first?["geometry"] as? [String: Any]
        }
        guard geometry?["type"] as? String == "LineString",
              let coordinates = geometry?["coordinates"] as? [[Double]],
              coordinates.count <= RouteGeometry.maximumPoints else {
            throw RouteError.invalid("Invalid or oversized route geometry.")
        }
        return try RouteGeometry(points: coordinates.map {
            guard $0.count >= 2 else { throw RouteError.invalid("A route coordinate is incomplete.") }
            return try RouteCoordinate(latitude: $0[1], longitude: $0[0])
        })
    }
}
