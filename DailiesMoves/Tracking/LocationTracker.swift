import Foundation
import CoreLocation
import CoreMotion
import Observation

/// Arc-grade, low-battery background location tracker.
///
/// Power & Reliability Architecture:
/// - **Sleeping state (~90% of the day)**:
///   - Keeps `CLLocationManager` alive in `kCLLocationAccuracyThreeKilometers` + `distanceFilter = kCLDistanceFilterNone`
///     (GPS radio OFF; cell/Wi-Fi only, nanosecond early-exit in delegate -> near-zero CPU/battery) with
///     `allowsBackgroundLocationUpdates = true` and `pausesLocationUpdatesAutomatically = false` so iOS NEVER
///     suspends the process between trips.
///   - Holds a single foreground-created `CLBackgroundActivitySession` across the tracking session (never
///     invalidated on sleep, since Apple only honors `CLBackgroundActivitySession` created in the foreground).
///   - Arms 4 ultra-low-power hardware wake triggers:
///     1. CoreMotion M-coprocessor (`CMMotionActivityManager`) — instant wake (<5s) on walking/biking/scooter/car.
///     2. Tight 50m exit `CLCircularRegion` geofence.
///     3. `CLVisit` arrival/departure monitoring.
///     4. Significant Location Changes (OS relaunch failsafe if terminated).
/// - **Moving state (active travel only)**:
///   - Immediately ramps `desiredAccuracy` to `kCLLocationAccuracyBest` (or `NearestTenMeters` in Power Saver)
///     with `distanceFilter = 10m` (smooth Arc-grade route curves).
///   - Zero background processing: raw points append directly to SQLite WAL.
///   - Watchdog timer (active ONLY while moving) detects 2 minutes of genuine stillness within 35m and
///     immediately drops back to 3km sleep mode (shutting down the GPS radio and stopping the timer).
@MainActor
@Observable
final class LocationTracker: NSObject {
    static let shared = LocationTracker(database: .shared)

    enum PowerProfile: String, CaseIterable, Identifiable, Sendable {
        case balanced = "balanced"
        case ultraLow = "ultraLow"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .balanced: return "Arc-Grade (Recommended)"
            case .ultraLow: return "Power Saver"
            }
        }

        var subtitle: String {
            switch self {
            case .balanced: return "Best GPS & 10m filter while moving; 3km sleep when stationary"
            case .ultraLow: return "10m GPS & 20m filter while moving; 3km sleep when stationary"
            }
        }

        var desiredAccuracy: CLLocationAccuracy {
            switch self {
            case .balanced: return kCLLocationAccuracyBest
            case .ultraLow: return kCLLocationAccuracyNearestTenMeters
            }
        }

        var distanceFilter: CLLocationDistance {
            switch self {
            case .balanced: return 10
            case .ultraLow: return 20
            }
        }

        var geofenceRadius: CLLocationDistance {
            switch self {
            case .balanced: return 50
            case .ultraLow: return 65
            }
        }

        var stationaryRadius: CLLocationDistance {
            switch self {
            case .balanced: return 35
            case .ultraLow: return 40
            }
        }

        var stationaryTimeout: TimeInterval {
            switch self {
            case .balanced: return 120 // 2 minutes of stillness -> sleep
            case .ultraLow: return 120
            }
        }
    }

    enum TrackingState: String, Sendable {
        case stopped
        case sleeping
        case moving

        var label: String {
            switch self {
            case .stopped: return "Off"
            case .sleeping: return "Sleeping (GPS Off)"
            case .moving: return "Recording Move (GPS)"
            }
        }
    }

    private static let enabledKey = "dailies.tracking.enabled"
    private static let powerProfileKey = "dailies.tracking.powerProfile"
    nonisolated private static let geofenceID = "dailies.stationary.exit"

    private let database: LocationDatabase
    private let manager: CLLocationManager
    private let motionManager = CMMotionActivityManager()

    /// Created in foreground and retained for the entire enabled session so iOS 17–26 never drops background access after sleep.
    private var backgroundSession: CLBackgroundActivitySession?
    /// Runs ONLY while `.moving` to return to 3km sleep even when indoors (`distanceFilter` stops firing).
    private var stationaryWatchdog: Timer?
    private var foregroundFixResetTask: Task<Void, Never>?

    private(set) var isEnabled: Bool
    private(set) var state: TrackingState = .stopped
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var motionAuthorizationStatus: CMAuthorizationStatus
    private(set) var lastSampleDate: Date?
    private(set) var isMotionCurrentlyMoving: Bool = false

    var powerProfile: PowerProfile {
        didSet {
            UserDefaults.standard.set(powerProfile.rawValue, forKey: Self.powerProfileKey)
            if state == .moving {
                applyActiveGPSConfiguration()
            }
        }
    }

    /// O(1) stationary dwell tracking while moving.
    private var stationaryAnchor: CLLocation?
    private var lastAnchorResetDate: Date = Date()
    private var enteredMovingDate: Date = Date()
    private var stationaryFixCount: Int = 0
    private var lastKnownLocation: CLLocation?
    private var lastMotionMovingDate: Date?
    private var isForegroundOneShotActive: Bool = false

    init(database: LocationDatabase) {
        self.database = database
        self.manager = CLLocationManager()
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.authorizationStatus = manager.authorizationStatus
        self.motionAuthorizationStatus = CMMotionActivityManager.authorizationStatus()
        let savedProfile = UserDefaults.standard.string(forKey: Self.powerProfileKey)
            .flatMap(PowerProfile.init(rawValue:)) ?? .balanced
        self.powerProfile = savedProfile

        super.init()

        manager.delegate = self
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = false

        if let latest = database.fetchLatestSample() {
            lastSampleDate = latest.timestamp
            lastKnownLocation = CLLocation(
                coordinate: latest.coordinate,
                altitude: latest.altitude,
                horizontalAccuracy: latest.horizontalAccuracy,
                verticalAccuracy: -1,
                course: latest.course,
                speed: latest.speed,
                timestamp: latest.timestamp
            )
        }
    }

    /// Called on app launch (including silent background location launches) to immediately re-arm tracking.
    func restoreIfNeeded(launchedForLocation: Bool = false) {
        authorizationStatus = manager.authorizationStatus
        motionAuthorizationStatus = CMMotionActivityManager.authorizationStatus()
        guard isEnabled else {
            state = .stopped
            return
        }
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else {
            return
        }

        ensureBackgroundSession()
        armFailsafeMonitors()
        startMotionWakeMonitorIfAuthorized()

        if launchedForLocation {
            enterMovingState(initialLocation: lastKnownLocation)
        } else if state == .stopped {
            enterSleepingState(around: lastKnownLocation)
        }
    }

    /// Called whenever the user brings the app to the foreground.
    /// Ensures a valid foreground-originated `CLBackgroundActivitySession` and refreshes location if stale.
    func handleAppBecameActive() {
        authorizationStatus = manager.authorizationStatus
        motionAuthorizationStatus = CMMotionActivityManager.authorizationStatus()
        guard isEnabled else { return }
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else { return }

        ensureBackgroundSession()
        armFailsafeMonitors()
        startMotionWakeMonitorIfAuthorized()

        if state == .stopped {
            enterSleepingState(around: lastKnownLocation)
        }

        guard state == .sleeping else { return }
        let staleness = lastSampleDate.map { Date().timeIntervalSince($0) } ?? .infinity
        guard staleness > 60 else { return }

        // Briefly pulse accuracy for a single clean fix (up to 6s), then return to 3km sleep if still stationary.
        isForegroundOneShotActive = true
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.startUpdatingLocation()

        foregroundFixResetTask?.cancel()
        foregroundFixResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            if self.isForegroundOneShotActive && self.state == .sleeping {
                self.isForegroundOneShotActive = false
                self.applySleepGPSConfiguration()
            }
        }
    }

    func requestPermissions() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
        requestMotionPermissionIfNeeded()
    }

    func requestMotionPermissionIfNeeded() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        let status = CMMotionActivityManager.authorizationStatus()
        guard status == .notDetermined else {
            motionAuthorizationStatus = status
            if status == .authorized && isEnabled {
                startMotionWakeMonitorIfAuthorized()
            }
            return
        }
        let now = Date()
        motionManager.queryActivityStarting(from: now.addingTimeInterval(-60), to: now, to: .main) { [weak self] _, _ in
            guard let self else { return }
            self.motionAuthorizationStatus = CMMotionActivityManager.authorizationStatus()
            if self.motionAuthorizationStatus == .authorized && self.isEnabled {
                self.startMotionWakeMonitorIfAuthorized()
            }
        }
    }

    func setTrackingEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)

        if enabled {
            if authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
                return
            }
            if authorizationStatus == .authorizedWhenInUse {
                manager.requestAlwaysAuthorization()
            }
            ensureBackgroundSession()
            requestMotionPermissionIfNeeded()
            armFailsafeMonitors()
            startMotionWakeMonitorIfAuthorized()
            enterMovingState(initialLocation: lastKnownLocation)
        } else {
            stopAllMonitoring()
        }
    }

    // MARK: - Power State Machine

    private func ensureBackgroundSession() {
        if backgroundSession == nil {
            backgroundSession = CLBackgroundActivitySession()
        }
    }

    private func armFailsafeMonitors() {
        if authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
        }
        manager.pausesLocationUpdatesAutomatically = false
        manager.startMonitoringVisits()
        manager.startMonitoringSignificantLocationChanges()
    }

    private func startMotionWakeMonitorIfAuthorized() {
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .authorized else {
            return
        }
        motionManager.stopActivityUpdates()
        motionManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, self.isEnabled, let activity else { return }
            let isMoving = (activity.walking || activity.running || activity.cycling || activity.automotive)
                && activity.confidence != .low
            let isStationary = activity.stationary && !isMoving && activity.confidence != .low

            if isMoving {
                self.isMotionCurrentlyMoving = true
                self.lastMotionMovingDate = Date()
                if self.state == .sleeping {
                    self.enterMovingState(initialLocation: self.lastKnownLocation)
                }
            } else if isStationary {
                self.isMotionCurrentlyMoving = false
            }
        }
    }

    private func enterSleepingState(around location: CLLocation?) {
        stopStationaryWatchdog()
        foregroundFixResetTask?.cancel()
        isForegroundOneShotActive = false
        stationaryAnchor = nil
        stationaryFixCount = 0
        state = .sleeping

        // IMPORTANT: Do NOT invalidate `backgroundSession` here!
        // Switching to kCLLocationAccuracyThreeKilometers turns OFF the GPS hardware while keeping
        // the foreground-established background session intact for the next departure.
        applySleepGPSConfiguration()

        if let location {
            armExitGeofence(around: location)
        }
    }

    private func enterMovingState(initialLocation: CLLocation?) {
        guard isEnabled else { return }
        foregroundFixResetTask?.cancel()
        isForegroundOneShotActive = false
        clearExitGeofence()
        ensureBackgroundSession()

        let now = Date()
        enteredMovingDate = now
        stationaryAnchor = initialLocation
        lastAnchorResetDate = now
        stationaryFixCount = 0
        state = .moving

        applyActiveGPSConfiguration()
        startStationaryWatchdog()
    }

    /// GPS hardware OFF (cell/Wi-Fi only). `kCLDistanceFilterNone` keeps CoreLocation's background keep-alive
    /// active so iOS never suspends the app between trips, while `didUpdateLocations` early-exits in nanoseconds.
    private func applySleepGPSConfiguration() {
        if authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
        }
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = kCLDistanceFilterNone
        manager.startUpdatingLocation()
    }

    /// Active travel mode: smooth Arc-grade GPS capture with zero auto-pausing mid-trip.
    private func applyActiveGPSConfiguration() {
        if authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
        }
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
        manager.desiredAccuracy = powerProfile.desiredAccuracy
        manager.distanceFilter = powerProfile.distanceFilter
        manager.startUpdatingLocation()
    }

    private func armExitGeofence(around location: CLLocation) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        clearExitGeofence()

        let baseRadius = powerProfile.geofenceRadius
        let accuracyPadded = max(baseRadius, min(100, location.horizontalAccuracy + 15))
        let clampedRadius = min(accuracyPadded, manager.maximumRegionMonitoringDistance)

        let region = CLCircularRegion(
            center: location.coordinate,
            radius: clampedRadius,
            identifier: Self.geofenceID
        )
        region.notifyOnEntry = false
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
    }

    private func clearExitGeofence() {
        for region in manager.monitoredRegions where region.identifier == Self.geofenceID {
            manager.stopMonitoring(for: region)
        }
    }

    private func startStationaryWatchdog() {
        stopStationaryWatchdog()
        stationaryWatchdog = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateWatchdogTimeout()
            }
        }
    }

    private func stopStationaryWatchdog() {
        stationaryWatchdog?.invalidate()
        stationaryWatchdog = nil
    }

    private func evaluateWatchdogTimeout() {
        guard isEnabled, state == .moving else {
            stopStationaryWatchdog()
            return
        }
        let now = Date()
        // Never prematurely sleep right after entering moving state.
        guard now.timeIntervalSince(enteredMovingDate) >= 90 else { return }

        let idleSeconds = now.timeIntervalSince(lastAnchorResetDate)
        let motionRecentlyActive = lastMotionMovingDate.map { now.timeIntervalSince($0) < 45 } ?? false
        let threshold = (isMotionCurrentlyMoving || motionRecentlyActive)
            ? max(powerProfile.stationaryTimeout, 210)
            : powerProfile.stationaryTimeout

        if idleSeconds >= threshold {
            // Drop cleanly back to 3km sleep WITHOUT writing a duplicate stale point.
            enterSleepingState(around: stationaryAnchor ?? lastKnownLocation)
        }
    }

    private func stopAllMonitoring() {
        stopStationaryWatchdog()
        foregroundFixResetTask?.cancel()
        isForegroundOneShotActive = false
        motionManager.stopActivityUpdates()
        manager.stopUpdatingLocation()
        manager.stopMonitoringVisits()
        manager.stopMonitoringSignificantLocationChanges()
        clearExitGeofence()
        manager.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
        stationaryAnchor = nil
        stationaryFixCount = 0
        state = .stopped
    }

    // MARK: - Zero-Processing Persistence

    private func recordSample(
        _ location: CLLocation,
        source: RawLocationSample.SampleSource,
        allowStale: Bool = false
    ) {
        guard location.horizontalAccuracy >= 0 else { return }
        let maxAllowedAcc: Double = (source == .visitAnchor) ? 150 : 85
        guard location.horizontalAccuracy <= maxAllowedAcc else { return }

        if !allowStale && source == .activeGPS && abs(location.timestamp.timeIntervalSinceNow) > 45 {
            return
        }

        database.appendSample(
            timestamp: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            altitude: location.altitude,
            speed: location.speed,
            course: location.course,
            source: source
        )
        lastKnownLocation = location
        lastSampleDate = location.timestamp
    }

    private func evaluateStationaryAnchor(with location: CLLocation) {
        guard state == .moving else { return }
        guard location.horizontalAccuracy > 0, location.horizontalAccuracy <= 50 else { return }

        // If GPS reports active walking/riding speed, we are definitely moving — reset anchor!
        if location.speed >= 0.8 {
            stationaryAnchor = location
            lastAnchorResetDate = Date()
            stationaryFixCount = 0
            return
        }

        guard let anchor = stationaryAnchor else {
            stationaryAnchor = location
            lastAnchorResetDate = Date()
            stationaryFixCount = 1
            return
        }

        let moved = location.distance(from: anchor)
        if moved > powerProfile.stationaryRadius {
            stationaryAnchor = location
            lastAnchorResetDate = Date()
            stationaryFixCount = 1
            return
        }

        stationaryFixCount += 1
        let dwell = location.timestamp.timeIntervalSince(anchor.timestamp)
        if dwell >= powerProfile.stationaryTimeout && stationaryFixCount >= 2 && !isMotionCurrentlyMoving {
            enterSleepingState(around: location)
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationTracker: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if self.isEnabled && (status == .authorizedAlways || status == .authorizedWhenInUse) {
                self.ensureBackgroundSession()
                self.armFailsafeMonitors()
                self.startMotionWakeMonitorIfAuthorized()
                if self.state == .stopped {
                    self.enterMovingState(initialLocation: self.lastKnownLocation)
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !locations.isEmpty else { return }
        Task { @MainActor in
            guard self.isEnabled else { return }

            switch self.state {
            case .moving:
                for loc in locations {
                    self.recordSample(loc, source: .activeGPS)
                }
                if let newest = locations.last {
                    self.evaluateStationaryAnchor(with: newest)
                }

            case .sleeping:
                guard let newest = locations.last else { return }

                // Foreground one-shot check
                if self.isForegroundOneShotActive {
                    if newest.horizontalAccuracy >= 0 && newest.horizontalAccuracy <= 65 {
                        let prev = self.lastKnownLocation
                        self.isForegroundOneShotActive = false
                        self.foregroundFixResetTask?.cancel()
                        self.recordSample(newest, source: .singleFix)
                        if let prev, newest.distance(from: prev) > self.powerProfile.geofenceRadius {
                            self.enterMovingState(initialLocation: newest)
                        } else {
                            self.applySleepGPSConfiguration()
                            self.armExitGeofence(around: newest)
                        }
                    }
                    return
                }

                // Fast O(1) sleep keep-alive check: ignore coarse/stationary ticks with ZERO DB writes.
                guard newest.horizontalAccuracy >= 0, newest.horizontalAccuracy <= 85 else { return }
                if let prev = self.lastKnownLocation {
                    let displacement = newest.distance(from: prev)
                    if displacement > max(self.powerProfile.geofenceRadius, newest.horizontalAccuracy + 25) {
                        self.recordSample(newest, source: .significantChange)
                        self.enterMovingState(initialLocation: newest)
                    }
                } else {
                    self.recordSample(newest, source: .singleFix)
                    self.armExitGeofence(around: newest)
                }

            case .stopped:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Self.geofenceID else { return }
        Task { @MainActor in
            guard self.isEnabled else { return }
            self.enterMovingState(initialLocation: self.lastKnownLocation)
        }
    }

    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.isEnabled else { return }
            self.enterSleepingState(around: self.lastKnownLocation)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let arrival = (visit.arrivalDate == .distantPast) ? nil : visit.arrivalDate
        let departure = (visit.departureDate == .distantFuture) ? nil : visit.departureDate
        let coord = visit.coordinate
        let hAcc = visit.horizontalAccuracy

        Task { @MainActor in
            guard self.isEnabled else { return }
            self.database.appendVisit(
                arrivalDate: arrival,
                departureDate: departure,
                latitude: coord.latitude,
                longitude: coord.longitude,
                horizontalAccuracy: hAcc
            )

            let visitLoc = CLLocation(
                coordinate: coord,
                altitude: 0,
                horizontalAccuracy: hAcc,
                verticalAccuracy: -1,
                timestamp: departure ?? arrival ?? Date()
            )
            self.recordSample(visitLoc, source: .visitAnchor, allowStale: true)

            if departure != nil {
                if self.state == .sleeping {
                    self.enterMovingState(initialLocation: visitLoc)
                }
            } else if arrival != nil && !self.isMotionCurrentlyMoving {
                self.enterSleepingState(around: visitLoc)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Ignore transient kCLErrorLocationUnknown; never spin or retry aggressively.
    }
}
