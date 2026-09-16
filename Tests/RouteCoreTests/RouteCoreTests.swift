import XCTest
@testable import RouteCore

final class RouteCoreTests: XCTestCase {
    private func point(_ lat: Double = 0, _ lon: Double) throws -> RouteCoordinate {
        try RouteCoordinate(latitude: lat, longitude: lon)
    }
    private func geometry() throws -> RouteGeometry {
        try RouteGeometry(points: [point(0, 0), point(0, 0.001)])
    }
    private func route(_ name: String = "Test") throws -> SavedRoute {
        try SavedRoute(name: name, points: geometry().points, createdAt: Date(timeIntervalSince1970: 0))
    }
    private func xml(_ body: String) -> Data { Data("<gpx>\(body)</gpx>".utf8) }
    private let two = "<trkpt lat=\"25\" lon=\"121\"/><trkpt lat=\"25.001\" lon=\"121\"/>"

    func testCoordinatesRejectNonFiniteAndOutOfRange() {
        for value in [Double.nan, .infinity, -.infinity, 91, -91] {
            XCTAssertThrowsError(try point(value, 0))
        }
        XCTAssertThrowsError(try point(0, 181))
        XCTAssertThrowsError(try JSONDecoder().decode(RouteCoordinate.self,
            from: Data("{\"latitude\":999,\"longitude\":0}".utf8)))
    }
    func testDistanceAndEndpoints() throws {
        let g = try geometry()
        XCTAssertEqual(g.length, 111.1949, accuracy: 0.001)
        XCTAssertEqual(g.coordinate(at: -1), g.points[0])
        XCTAssertEqual(g.coordinate(at: 1e9), g.points[1])
        XCTAssertEqual(g.coordinate(at: g.length / 2).longitude, 0.0005, accuracy: 1e-9)
    }
    func testDuplicatePointsAreRemoved() throws {
        let a = try point(0, 0), b = try point(0, 1)
        XCTAssertEqual(try RouteGeometry(points: [a, a, b, b]).points.count, 2)
        XCTAssertThrowsError(try RouteGeometry(points: [a, a]))
        XCTAssertThrowsError(try RouteGeometry(points: []))
    }
    func testDatelineUsesShortArc() throws {
        let g = try RouteGeometry(points: [point(0, 179), point(0, -179)])
        XCTAssertEqual(abs(g.coordinate(at: g.length / 2).longitude), 180, accuracy: 1e-8)
        XCTAssertLessThan(g.length, 225_000)
    }
    func testAntipodalRejected() {
        XCTAssertThrowsError(try RouteGeometry(points: [point(0, 0), point(0, 180)]))
    }
    func testMultiSegmentInterpolation() throws {
        let g = try RouteGeometry(points: [point(0, 0), point(0, 1), point(0, 3)])
        XCTAssertEqual(g.coordinate(at: g.length * 2 / 3).longitude, 2, accuracy: 1e-8)
    }
    func testSpeedConversionAndJitter() throws {
        let g = try geometry()
        var p = RoutePlayer(geometry: g, options: try PlaybackOptions(speedKMH: 3.6, jitterPercent: 50))
        try p.advance(seconds: 1, randomUnit: 1)
        XCTAssertEqual(p.distanceAlongRoute, 1.5, accuracy: 1e-8)
        try p.advance(seconds: 1, randomUnit: 0)
        XCTAssertEqual(p.distanceAlongRoute, 2, accuracy: 1e-8)
    }
    func testPauseWithoutAdvanceAndFailureRollback() throws {
        var p = RoutePlayer(geometry: try geometry(), options: try PlaybackOptions(speedKMH: 3.6))
        try p.advance(seconds: 1)
        var rejected = p
        try rejected.advance(seconds: 1)
        XCTAssertEqual(p.distanceAlongRoute, 1, accuracy: 1e-8)
        XCTAssertEqual(rejected.distanceAlongRoute, 2, accuracy: 1e-8)
        XCTAssertThrowsError(try p.advance(seconds: 30))
        XCTAssertEqual(p.distanceAlongRoute, 1, accuracy: 1e-8)
    }
    func testPingPongNeverTeleportsAtEnd() throws {
        let g = try RouteGeometry(points: [point(0, 0), point(0, 0.00001)])
        var p = RoutePlayer(geometry: g, options: try PlaybackOptions(speedKMH: 3.6, pingPong: true))
        try p.advance(seconds: g.length + 0.1)
        XCTAssertEqual(p.distanceAlongRoute, g.length - 0.1, accuracy: 1e-8)
        XCTAssertFalse(p.hasArrived)
        try p.advance(seconds: g.length)
        XCTAssertEqual(p.distanceAlongRoute, 0.1, accuracy: 1e-8)
    }
    func testOnceClampsAtDestination() throws {
        let g = try RouteGeometry(points: [point(0, 0), point(0, 0.00001)])
        var p = RoutePlayer(geometry: g, options: try PlaybackOptions(speedKMH: 50))
        try p.advance(seconds: 1)
        XCTAssertTrue(p.hasArrived)
        XCTAssertEqual(p.current, g.points.last)
    }
    func testInvalidPlaybackInputsDoNotMutateState() throws {
        XCTAssertThrowsError(try PlaybackOptions(speedKMH: .nan))
        XCTAssertThrowsError(try PlaybackOptions(speedKMH: 0))
        XCTAssertThrowsError(try PlaybackOptions(jitterPercent: 51))
        var p = RoutePlayer(geometry: try geometry(), options: try PlaybackOptions())
        XCTAssertThrowsError(try p.advance(seconds: -.infinity))
        XCTAssertThrowsError(try p.advance(seconds: 1, randomUnit: 2))
        XCTAssertEqual(p.distanceAlongRoute, 0)
    }
    func testGPXRoundTripAndEscaping() throws {
        let original = try route("A & B <route> \"test\" '")
        let result = try GPXCodec.decode(GPXCodec.encode(original))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, original.name)
        XCTAssertEqual(result[0].points, original.points)
    }
    func testGPXSegmentsAreSeparateRoutes() throws {
        let routes = try GPXCodec.decode(xml("<trk><name>Walk</name><trkseg>\(two)</trkseg><trkseg>\(two)</trkseg></trk>"))
        XCTAssertEqual(routes.count, 2)
        XCTAssertEqual(routes.map(\.points.count), [2, 2])
        XCTAssertNotEqual(routes[0].name, routes[1].name)
    }
    func testGPXRouteAndWaypointFallbacks() throws {
        let rte = "<rte><name>R</name><rtept lat=\"0\" lon=\"0\"/><rtept lat=\"0\" lon=\"1\"/></rte>"
        XCTAssertEqual(try GPXCodec.decode(xml(rte))[0].name, "R")
        XCTAssertEqual(try GPXCodec.decode(xml("<wpt lat=\"0\" lon=\"0\"/><wpt lat=\"0\" lon=\"1\"/>"))[0].name, "Waypoints")
    }
    func testGPXPrefixedNamespace() throws {
        let data = Data("<p:gpx xmlns:p=\"http://www.topografix.com/GPX/1/1\"><p:trk><p:trkseg><p:trkpt lat=\"0\" lon=\"0\"/><p:trkpt lat=\"0\" lon=\"1\"/></p:trkseg></p:trk></p:gpx>".utf8)
        XCTAssertEqual(try GPXCodec.decode(data).count, 1)
    }
    func testGPXRejectsInvalidAndUnsafeDocuments() {
        for value in ["<gpx>", "<other/>", "<gpx/>", "<!DOCTYPE gpx><gpx/>",
                      "<!DOCTYPE gpx [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><gpx>&x;</gpx>",
                      "<gpx><wpt lat=\"nan\" lon=\"0\"/></gpx>",
                      "<gpx><wpt lat=\"999\" lon=\"0\"/></gpx>"] {
            XCTAssertThrowsError(try GPXCodec.decode(Data(value.utf8)))
        }
        XCTAssertThrowsError(try GPXCodec.decode(Data(repeating: 65, count: GPXCodec.maximumBytes + 1)))
    }
    func testGPXDoesNotReadExtensionPoints() {
        XCTAssertThrowsError(try GPXCodec.decode(xml("<extensions><trk><trkseg>\(two)</trkseg></trk></extensions>")))
    }
    func testNameValidation() {
        XCTAssertThrowsError(try route("  "))
        XCTAssertThrowsError(try route("bad\u{0}name"))
        XCTAssertThrowsError(try route(String(repeating: "x", count: 121)))
    }
    func testLibraryRoundTripAndMissingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("routes.json")
        XCTAssertEqual(try RouteLibrary.load(from: url), [])
        let original = try route()
        try RouteLibrary.save([original], to: url)
        XCTAssertEqual(try RouteLibrary.load(from: url), [original])
        let renamed = try original.renamed("Renamed")
        try RouteLibrary.save([renamed], to: url)
        XCTAssertEqual(try RouteLibrary.load(from: url)[0].id, original.id)
    }
    func testLibraryRejectsDuplicateIDsWithoutReplacingGoodFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try route()
        try RouteLibrary.save([original], to: url)
        XCTAssertThrowsError(try RouteLibrary.save([original, original], to: url))
        XCTAssertEqual(try RouteLibrary.load(from: url), [original])
    }
    func testLibraryCorruptionAndFutureVersionThrow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for text in ["broken", "{\"version\":2,\"routes\":[]}"] {
            try Data(text.utf8).write(to: url)
            XCTAssertThrowsError(try RouteLibrary.load(from: url))
            XCTAssertEqual(try String(contentsOf: url), text)
        }
    }
}
