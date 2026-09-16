import XCTest
@testable import RouteCore

final class WaypointTests: XCTestCase {
    private func p(_ lon: Double) throws -> RouteCoordinate { try RouteCoordinate(latitude: 0, longitude: lon) }
    private func waypoint(_ name: String, _ lon: Double) throws -> NamedWaypoint { try NamedWaypoint(name: name, coordinate: p(lon)) }

    func testBookmarkNameValidationAndIdentity() throws {
        let id = UUID()
        let a = try NamedWaypoint(id: id, name: "  Home  ", coordinate: p(1))
        XCTAssertEqual(a.name, "Home")
        let renamed = try NamedWaypoint(id: id, name: "Work", coordinate: a.coordinate)
        XCTAssertEqual(a.id, renamed.id)
        for name in ["  ", "a\nb", String(repeating: "x", count: 121)] {
            XCTAssertThrowsError(try waypoint(name, 1))
        }
    }
    func testBookmarkCodableRevalidates() throws {
        let a = try waypoint("Home", 1)
        let data = try JSONEncoder().encode(a)
        XCTAssertEqual(try JSONDecoder().decode(NamedWaypoint.self, from: data), a)
        let invalid = String(data: data, encoding: .utf8)!.replacingOccurrences(of: "Home", with: "")
        XCTAssertThrowsError(try JSONDecoder().decode(NamedWaypoint.self, from: Data(invalid.utf8)))
    }
    func testWaypointAddMoveReplaceDelete() throws {
        var d = WaypointDraft()
        let a = try waypoint("A", 0), b = try waypoint("B", 1), c = try waypoint("C", 2)
        try [a, b, c].forEach { try d.add($0) }
        try d.move(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(d.points.map(\.name), ["B", "C", "A"])
        try d.move(from: IndexSet([1, 2]), to: 0)
        XCTAssertEqual(d.points.map(\.name), ["C", "A", "B"])
        try d.replace(NamedWaypoint(id: a.id, name: "Renamed", coordinate: p(3)))
        XCTAssertEqual(d.points[1].coordinate, try p(3))
        d.remove(ids: [b.id])
        d.reverse()
        XCTAssertEqual(d.points.map(\.name), ["Renamed", "C"])
        d.clear()
        XCTAssertTrue(d.points.isEmpty)
    }
    func testInvalidEditsLeaveDraftUnchanged() throws {
        var d = WaypointDraft()
        let a = try waypoint("A", 0)
        try d.add(a)
        XCTAssertThrowsError(try d.add(a))
        XCTAssertThrowsError(try d.move(from: IndexSet(integer: 10), to: 0))
        XCTAssertThrowsError(try d.move(from: IndexSet(integer: 0), to: -1))
        XCTAssertThrowsError(try d.replace(waypoint("Missing", 2)))
        XCTAssertEqual(d.points, [a])
    }
    func testDraftLimit() throws {
        var d = WaypointDraft()
        for i in 0..<200 { try d.add(waypoint("P\(i)", Double(i) / 1000)) }
        XCTAssertThrowsError(try d.add(waypoint("Overflow", 3)))
        XCTAssertEqual(d.points.count, 200)
    }
    func testDraftNeedsTwoDistinctPointsOrAnAnchor() throws {
        var d = WaypointDraft()
        try d.add(waypoint("Tail", 1))
        XCTAssertThrowsError(try d.geometry())
        XCTAssertEqual(try d.geometry(after: p(0)).points, try [p(0), p(1)])
        XCTAssertThrowsError(try d.geometry(after: p(1)))
    }
    func testAppendMidSegmentPreservesCoordinateAndDistance() throws {
        var player = RoutePlayer(geometry: try RouteGeometry(points: [p(0), p(0.001)]), options: try PlaybackOptions(speedKMH: 3.6))
        try player.advance(seconds: 2)
        let before = player.current, distance = player.distanceAlongRoute
        try player.append([p(0.001), p(0.002)])
        XCTAssertEqual(player.current.latitude, before.latitude, accuracy: 1e-12)
        XCTAssertEqual(player.current.longitude, before.longitude, accuracy: 1e-12)
        XCTAssertEqual(player.distanceAlongRoute, distance, accuracy: 1e-12)
        try player.advance(seconds: 1)
        XCTAssertEqual(player.distanceAlongRoute, 3, accuracy: 1e-10)
    }
    func testAppendAtArrivalMakesMoreDistanceAvailable() throws {
        var player = RoutePlayer(geometry: try RouteGeometry(points: [p(0), p(0.00001)]), options: try PlaybackOptions(speedKMH: 3.6))
        try player.advance(seconds: 5)
        XCTAssertTrue(player.hasArrived)
        let before = player.current
        try player.append([p(0.00002)])
        XCTAssertFalse(player.hasArrived)
        XCTAssertEqual(player.current.longitude, before.longitude, accuracy: 1e-12)
    }
    func testAppendOnReturnLegPreservesDirection() throws {
        let geometry = try RouteGeometry(points: [p(0), p(0.00001)])
        var player = RoutePlayer(geometry: geometry, options: try PlaybackOptions(speedKMH: 3.6, pingPong: true))
        try player.advance(seconds: geometry.length + 0.2)
        let before = player.current, distance = player.distanceAlongRoute
        try player.append([p(0.00002)])
        XCTAssertEqual(player.current.longitude, before.longitude, accuracy: 1e-12)
        try player.advance(seconds: 0.1)
        XCTAssertEqual(player.distanceAlongRoute, distance - 0.1, accuracy: 1e-10)
    }
    func testFailedAppendIsTransactional() throws {
        var player = RoutePlayer(geometry: try RouteGeometry(points: [p(0), p(1)]), options: try PlaybackOptions())
        try player.advance(seconds: 1)
        let before = player.current, length = player.geometry.length
        XCTAssertThrowsError(try player.append([]))
        XCTAssertThrowsError(try player.append([p(1)]))
        XCTAssertThrowsError(try player.append([p(-179)]))
        XCTAssertEqual(player.current, before)
        XCTAssertEqual(player.geometry.length, length)
    }
    func testOSRMRequestUsesLongitudeLatitudeAndNoKey() throws {
        let points = try [RouteCoordinate(latitude: 25, longitude: 121), RouteCoordinate(latitude: 26, longitude: 122)]
        let request = try RoutingHTTP.request(points: points, provider: .osrmDriving, key: "must-not-send")
        XCTAssertEqual(request.url?.host, "router.project-osrm.org")
        XCTAssertTrue(request.url!.absoluteString.contains("121.0,25.0;122.0,26.0"))
        XCTAssertTrue(request.url!.absoluteString.contains("geometries=geojson"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
    func testORSProfilesAndKeyPlacement() throws {
        for provider in [RoadProvider.orsWalking, .orsCycling, .orsDriving] {
            let r = try RoutingHTTP.request(points: [p(0), p(1)], provider: provider, key: "fixture-key")
            XCTAssertEqual(r.httpMethod, "POST")
            XCTAssertEqual(r.url?.host, "api.openrouteservice.org")
            XCTAssertTrue(r.url!.path.contains(provider.profile))
            XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "fixture-key")
            XCTAssertFalse(r.url!.absoluteString.contains("fixture-key"))
            let json = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: [[Double]]]
            XCTAssertEqual(json["coordinates"], [[0,0],[1,0]])
        }
    }
    func testRoutingRequestRejectsMissingKeyAndExcessWaypoints() throws {
        XCTAssertThrowsError(try RoutingHTTP.request(points: [p(0), p(1)], provider: .orsWalking))
        XCTAssertThrowsError(try RoutingHTTP.request(points: [p(0), p(1)], provider: .orsWalking, key: "x\r\ny"))
        XCTAssertThrowsError(try RoutingHTTP.request(points: [p(0)], provider: .osrmDriving))
        XCTAssertThrowsError(try RoutingHTTP.request(points: Array(repeating: p(0), count: 51), provider: .osrmDriving))
    }
    func testRouteResponseFormatsAndAltitude() throws {
        let geometry = "{\"type\":\"LineString\",\"coordinates\":[[121,25,10],[121.1,25.1,12]]}"
        let osrm = Data("{\"code\":\"Ok\",\"routes\":[{\"geometry\":\(geometry)}]}".utf8)
        let ors = Data("{\"features\":[{\"geometry\":\(geometry)}]}".utf8)
        let a = try RoutingHTTP.decode(osrm, status: 200, provider: .osrmDriving)
        let b = try RoutingHTTP.decode(ors, status: 200, provider: .orsWalking)
        XCTAssertEqual(a.points, b.points)
        XCTAssertEqual(a.points[0].latitude, 25)
    }
    func testRouteResponseErrors() {
        for status in [401,403,429,500] { XCTAssertThrowsError(try RoutingHTTP.decode(Data(), status: status, provider: .orsWalking)) }
        for json in ["{}", "{\"code\":\"NoRoute\"}", "{\"code\":\"Ok\",\"routes\":[{\"geometry\":{\"type\":\"Point\",\"coordinates\":[[0,0],[1,0]]}}]}"] {
            XCTAssertThrowsError(try RoutingHTTP.decode(Data(json.utf8), status: 200, provider: .osrmDriving))
        }
    }
}
