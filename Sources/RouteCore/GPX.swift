import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum GPXCodec {
    public static let maximumBytes = 5 * 1024 * 1024

    /// Each track segment becomes a separate route: gaps are never silently joined.
    public static func decode(_ data: Data) throws -> [SavedRoute] {
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else {
            throw RouteError.invalid("GPX must be UTF-8 and no larger than 5 MiB.")
        }
        let upper = text.uppercased()
        guard !upper.contains("<!DOCTYPE"), !upper.contains("<!ENTITY") else {
            throw RouteError.invalid("GPX documents with DTDs or entities are not supported.")
        }
        let delegate = GPXReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil else {
            throw delegate.failure ?? RouteError.invalid("The GPX document is malformed.")
        }
        return try delegate.routes()
    }

    public static func encode(_ route: SavedRoute) -> Data {
        let points = route.points.map {
            "      <trkpt lat=\"\($0.latitude)\" lon=\"\($0.longitude)\"/>"
        }.joined(separator: "\n")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="iFakeGPS-iOS" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><name>\(escape(route.name))</name><trkseg>
        \(points)
          </trkseg></trk>
        </gpx>
        """
        return Data(xml.utf8)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private final class GPXReader: NSObject, XMLParserDelegate {
    var failure: Error?
    private var path: [String] = []
    private var foundRoot = false
    private var name = ""
    private var segments: [[RouteCoordinate]] = []
    private var points: [RouteCoordinate] = []
    private var waypoints: [RouteCoordinate] = []
    private var tracks: [(String, [[RouteCoordinate]])] = []
    private var namedRoutes: [(String, [RouteCoordinate])] = []
    private var count = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        path.append(elementName)
        if path.count == 1 {
            foundRoot = elementName == "gpx" &&
                (namespaceURI == nil || namespaceURI == "" ||
                 namespaceURI == "http://www.topografix.com/GPX/1/1" ||
                 namespaceURI == "http://www.topografix.com/GPX/1/0")
            if !foundRoot { fail(parser, "Not a supported GPX document.") }
        }
        guard path.count <= 64 else { fail(parser, "GPX nesting is too deep."); return }
        if path == ["gpx", "trk"] { name = ""; segments = [] }
        if path == ["gpx", "rte"] { name = ""; points = [] }
        if path == ["gpx", "trk", "trkseg"] { points = [] }
        guard path == ["gpx", "trk", "trkseg", "trkpt"] ||
                path == ["gpx", "rte", "rtept"] || path == ["gpx", "wpt"] else { return }
        count += 1
        guard count <= RouteGeometry.maximumPoints else {
            fail(parser, "A GPX import may contain at most 50,000 points."); return
        }
        guard let latitude = attributes["lat"].flatMap(Double.init),
              let longitude = attributes["lon"].flatMap(Double.init),
              let point = try? RouteCoordinate(latitude: latitude, longitude: longitude) else {
            fail(parser, "A GPX point has invalid coordinates."); return
        }
        if path == ["gpx", "wpt"] { waypoints.append(point) } else { points.append(point) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if path == ["gpx", "trk", "name"] || path == ["gpx", "rte", "name"] {
            name += string
            if name.count > 120 { fail(parser, "GPX route names may contain at most 120 characters.") }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if path == ["gpx", "trk", "trkseg"] { segments.append(points); points = [] }
        if path == ["gpx", "trk"] { tracks.append((name, segments)) }
        if path == ["gpx", "rte"] { namedRoutes.append((name, points)); points = [] }
        if !path.isEmpty { path.removeLast() }
    }

    func routes() throws -> [SavedRoute] {
        guard foundRoot else { throw RouteError.invalid("The document has no GPX root.") }
        var result: [SavedRoute] = []
        if !tracks.isEmpty {
            for (index, track) in tracks.enumerated() {
                let title = track.0.trimmingCharacters(in: .whitespacesAndNewlines)
                let base = title.isEmpty ? "Track \(index + 1)" : title
                for (segmentIndex, segment) in track.1.enumerated() {
                    let suffix = track.1.count > 1 ? " - segment \(segmentIndex + 1)" : ""
                    result.append(try SavedRoute(name: String(base.prefix(100)) + suffix, points: segment))
                }
            }
        } else if !namedRoutes.isEmpty {
            for (index, route) in namedRoutes.enumerated() {
                let name = route.0.trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(try SavedRoute(name: name.isEmpty ? "Route \(index + 1)" : name, points: route.1))
            }
        } else if !waypoints.isEmpty {
            result.append(try SavedRoute(name: "Waypoints", points: waypoints))
        }
        guard !result.isEmpty else { throw RouteError.invalid("GPX contains no usable track or route.") }
        return result
    }

    private func fail(_ parser: XMLParser, _ message: String) {
        if failure == nil { failure = RouteError.invalid(message) }
        parser.abortParsing()
    }
}
