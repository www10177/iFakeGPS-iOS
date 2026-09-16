// iFakeGPS-iOS adapter for Roam Control Build 61. Keep the upstream transport intact.
import CoreLocation
import Foundation
import MapKit
import Observation

enum WalkingPace: Double, CaseIterable, Identifiable {
    case relaxed = 1.0, normal = 1.4, brisk = 1.8
    var id: Self { self }
    var title: String {
        switch self { case .relaxed: "Relaxed"; case .normal: "Normal"; case .brisk: "Brisk" }
    }
    var metresPerSecond: Double { rawValue }
}

enum WalkingSimulationPhase: Equatable {
    case idle, preparing, walking, paused, arrived, stopping
    case failed(String)
}

@MainActor @Observable
final class WalkingSimulationController {
    private(set) var phase: WalkingSimulationPhase = .idle
    private(set) var currentCoordinate: CLLocationCoordinate2D?
    private(set) var distanceTravelled: CLLocationDistance = 0
    private(set) var totalDistance: CLLocationDistance = 0
    private(set) var destination: LocationTarget?
    private(set) var isCustomRoute = false
    private(set) var customPolyline: MKPolyline?
    private(set) var interruptionNotice: String?

    // Preserve the upstream pace API for recovery and legacy controls.
    var pace: WalkingPace = .normal { didSet { speedKMH = pace.metresPerSecond * 3.6 } }
    var speedKMH = 5.04
    var speedVariationPercent = 0.0
    var loopRoute = false

    @ObservationIgnored private var geometry: RouteGeometry?
    @ObservationIgnored private var player: RoutePlayer?
    @ObservationIgnored private var routeStart: LocationTarget?
    @ObservationIgnored private var movementTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var routeRevision: UInt64 = 0
    @ObservationIgnored private var routeName = "Route"

    var editToken: String { "\(generation):\(routeRevision)" }
    var routeEnd: RouteCoordinate? { geometry?.points.last }
    var canAppendWaypoints: Bool {
        player != nil && (phase == .walking || phase == .paused || phase == .arrived)
    }
    var progress: Double { totalDistance > 0 ? min(max(distanceTravelled / totalDistance, 0), 1) : 0 }
    var remainingDistance: CLLocationDistance { max(totalDistance - distanceTravelled, 0) }
    var remainingDuration: TimeInterval { remainingDistance / max(speedKMH / 3.6, 0.01) }
    var locksDestination: Bool {
        switch phase {
        case .preparing, .walking, .paused, .arrived, .stopping: true
        case .idle, .failed: false
        }
    }
    var exportableRoute: SavedRoute? {
        guard let geometry else { return nil }
        return try? SavedRoute(name: String(routeName.prefix(120)), points: geometry.points)
    }

    func prepare(route: MKRoute, destination: LocationTarget) {
        do {
            let polyline = route.polyline
            let points = try (0..<polyline.pointCount).map {
                let coordinate = polyline.points()[$0].coordinate
                return try RouteCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
            }
            try prepare(points: points, destination: destination, name: destination.name, custom: false)
        } catch { phase = .failed(error.localizedDescription) }
    }

    func prepare(savedRoute: SavedRoute) throws {
        guard let last = savedRoute.points.last else { throw RouteError.invalid("This route is empty.") }
        let destination = LocationTarget(name: savedRoute.name, subtitle: "Saved GPX route",
                                         latitude: last.latitude, longitude: last.longitude)
        try prepare(points: savedRoute.points, destination: destination, name: savedRoute.name, custom: true)
    }

    private func prepare(points: [RouteCoordinate], destination: LocationTarget, name: String, custom: Bool) throws {
        let geometry = try RouteGeometry(points: points)
        cancelMovement()
        routeRevision &+= 1
        self.geometry = geometry
        player = nil
        totalDistance = geometry.length
        distanceTravelled = 0
        currentCoordinate = nil
        self.destination = destination
        routeName = name
        isCustomRoute = custom
        interruptionNotice = nil
        let first = geometry.points[0]
        routeStart = LocationTarget(name: "Route Start", subtitle: name,
                                    latitude: first.latitude, longitude: first.longitude)
        let coordinates = geometry.points.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        customPolyline = custom ? MKPolyline(coordinates: coordinates, count: coordinates.count) : nil
        phase = .idle
    }

    func prepareReturnTrip() -> LocationTarget? {
        guard phase == .arrived, let geometry, let target = routeStart,
              let previousDestination = destination else { return nil }
        do {
            try prepare(points: Array(geometry.points.reversed()), destination: target,
                        name: routeName, custom: isCustomRoute)
            routeStart = previousDestination
            return target
        } catch { phase = .failed(error.localizedDescription); return nil }
    }

    func start(using appModel: AppModel) async {
        guard let geometry, let destination, phase == .idle || isFailed else { return }
        guard case .paired = appModel.pairingStatus else {
            phase = .failed("Pair this iPhone before starting a route."); return
        }
        do {
            let options = try currentOptions()
            cancelMovement()
            let token = generation
            player = RoutePlayer(geometry: geometry, options: options)
            distanceTravelled = 0
            currentCoordinate = coordinate(geometry.points[0])
            interruptionNotice = nil
            phase = .preparing
            let initial = target(at: geometry.points[0])
            if isCustomRoute {
                // Upstream recovery knows only start/destination, not GPX geometry.
                // Recover a fixed position, never silently replan a GPX route in MapKit.
                await appModel.startLocationSession(at: initial)
            } else {
                await appModel.startWalkingLocationSession(at: initial, destination: destination,
                                                          paceMetresPerSecond: options.speedKMH / 3.6)
            }
            guard generation == token, phase == .preparing else { return }
            switch appModel.deviceSession.phase {
            case .active:
                // Updating an already-active fixed session does not emit a phase change.
                handleDeviceSessionPhase(appModel.deviceSession.phase, deviceSession: appModel.deviceSession)
            case .idle: phase = .failed("The device session did not start.")
            case .failed(let message): phase = .failed(message)
            default: break
            }
        } catch { phase = .failed(error.localizedDescription) }
    }

    func appendWaypoints(_ points: [RouteCoordinate], using appModel: AppModel) throws {
        guard canAppendWaypoints, case .active = appModel.deviceSession.phase, var candidate = player else {
            throw RouteError.invalid("Only an active or paused route can receive appended waypoints.")
        }
        try candidate.append(points)
        let wasArrived = phase == .arrived
        // The upstream recovery format cannot store arbitrary appended geometry.
        // Persist a fixed recovery target rather than silently re-routing on restart.
        appModel.preserveEditedRouteRecovery(at: target(at: candidate.current))
        player = candidate
        geometry = candidate.geometry
        totalDistance = candidate.geometry.length
        distanceTravelled = candidate.distanceAlongRoute
        routeRevision &+= 1
        isCustomRoute = true
        let coordinates = candidate.geometry.points.map(coordinate)
        customPolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        if let last = candidate.geometry.points.last { destination = target(at: last) }
        if wasArrived {
            phase = .paused
            interruptionNotice = String(localized: "Waypoints appended. Resume to continue from the endpoint.")
            beginMovement(using: appModel.deviceSession)
        }
    }

    func togglePause() {
        switch phase {
        case .walking: phase = .paused
        case .paused: interruptionNotice = nil; phase = .walking
        default: break
        }
    }

    func stop(using deviceSession: LocalDeviceSessionCoordinator) {
        cancelMovement()
        interruptionNotice = nil
        if case .idle = deviceSession.phase {
            currentCoordinate = nil
            distanceTravelled = 0
            phase = .idle
        } else {
            phase = .stopping
            deviceSession.stop()
        }
    }

    func handleDeviceSessionPhase(_ devicePhase: DeviceSessionPhase,
                                  deviceSession: LocalDeviceSessionCoordinator) {
        switch devicePhase {
        case .active:
            guard phase == .preparing else { return }
            phase = .walking
            beginMovement(using: deviceSession)
        case .stopping:
            guard locksDestination || isFailed else { return }
            cancelMovement()
            phase = .stopping
        case .idle:
            guard phase == .stopping else { return }
            cancelMovement()
            currentCoordinate = nil
            distanceTravelled = 0
            phase = .idle
        case .failed(let message):
            guard locksDestination || isFailed else { return }
            cancelMovement()
            phase = .failed(message)
        case .openingLocalDevVPN, .discovering, .connecting: break
        }
    }

    func reset() {
        cancelMovement()
        geometry = nil
        player = nil
        destination = nil
        routeStart = nil
        currentCoordinate = nil
        customPolyline = nil
        isCustomRoute = false
        interruptionNotice = nil
        distanceTravelled = 0
        totalDistance = 0
        phase = .idle
    }

    private var isFailed: Bool { if case .failed = phase { return true }; return false }
    private func currentOptions() throws -> PlaybackOptions {
        try PlaybackOptions(speedKMH: speedKMH, jitterPercent: speedVariationPercent, pingPong: loopRoute)
    }
    private func cancelMovement() {
        generation &+= 1
        movementTask?.cancel()
        movementTask = nil
    }

    private func beginMovement(using deviceSession: LocalDeviceSessionCoordinator) {
        movementTask?.cancel()
        let token = generation
        movementTask = Task { @MainActor [weak self, weak deviceSession] in
            var previousTick = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled, let self, let deviceSession, self.generation == token else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = now - previousTick
                previousTick = now
                if self.phase == .paused { continue }
                guard self.phase == .walking, var candidate = self.player else { return }
                if elapsed > 5 || elapsed < 0 {
                    self.interruptionNotice = "Playback was interrupted. Resume to continue from the last accepted position."
                    self.phase = .paused
                    continue
                }
                do {
                    candidate.options = try self.currentOptions()
                    let next = try candidate.advance(seconds: elapsed, randomUnit: Double.random(in: 0...1))
                    guard deviceSession.updateLocation(self.target(at: next)) == .updated else {
                        self.phase = .failed("Location update was not accepted. Stop & Restore before retrying.")
                        return
                    }
                    self.player = candidate
                    self.distanceTravelled = candidate.distanceAlongRoute
                    self.currentCoordinate = self.coordinate(next)
                    if candidate.hasArrived { self.phase = .arrived; return }
                } catch {
                    self.interruptionNotice = error.localizedDescription
                    self.phase = .paused
                }
            }
        }
    }

    private func target(at point: RouteCoordinate) -> LocationTarget {
        LocationTarget(name: routeName, subtitle: "iFakeGPS route simulation",
                       latitude: point.latitude, longitude: point.longitude)
    }
    private func coordinate(_ point: RouteCoordinate) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }
}
