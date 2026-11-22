import CoreLocation
import Foundation

enum LocationError: LocalizedError {
    case denied, unavailable

    var errorDescription: String? {
        switch self {
        case .denied: return "Location permission is off. Turn it on in Settings › PM Tracker › Location."
        case .unavailable: return "Couldn't get your location."
        }
    }
}

/// One-shot location lookups that work from the app and from Siri.
@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    @Published private(set) var authorization: CLAuthorizationStatus
    private let manager: CLLocationManager
    private var waiting: [CheckedContinuation<CLLocation, Error>] = []
    private var authWaiting: [CheckedContinuation<Void, Never>] = []
    private var generation = 0

    override init() {
        let m = CLLocationManager()
        manager = m
        authorization = m.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    var isAlways: Bool { authorization == .authorizedAlways }
    var isAllowed: Bool { authorization == .authorizedAlways || authorization == .authorizedWhenInUse }

    var statusText: String {
        switch authorization {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "While using the app"
        case .denied: return "Off"
        case .restricted: return "Restricted"
        default: return "Not asked yet"
        }
    }

    func requestWhenInUse() { manager.requestWhenInUseAuthorization() }

    /// Siri commands can only read your location reliably with Always permission.
    func requestAlways() { manager.requestAlwaysAuthorization() }

    private func waitForAuthorization() async {
        if manager.authorizationStatus != .notDetermined { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            authWaiting.append(c)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self.resumeAuthWaiters()
            }
        }
    }

    private func resumeAuthWaiters() {
        let list = authWaiting
        authWaiting = []
        list.forEach { $0.resume() }
    }

    /// Returns a fresh location. Falls back to a recent cached fix if a new one doesn't arrive in time.
    func current(maxAge: TimeInterval = 20, timeout: TimeInterval = 12) async throws -> CLLocation {
        if let l = manager.location, -l.timestamp.timeIntervalSinceNow < maxAge, l.horizontalAccuracy >= 0, l.horizontalAccuracy < 150 {
            return l
        }
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            await waitForAuthorization()
        }
        authorization = manager.authorizationStatus
        guard isAllowed else { throw LocationError.denied }

        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<CLLocation, Error>) in
            waiting.append(c)
            if waiting.count == 1 {
                generation += 1
                let gen = generation
                manager.requestLocation()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard gen == self.generation, !self.waiting.isEmpty else { return }
                    if let cached = self.manager.location, -cached.timestamp.timeIntervalSinceNow < 600 {
                        self.finish(.success(cached))
                    } else {
                        self.finish(.failure(LocationError.unavailable))
                    }
                }
            }
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        let list = waiting
        waiting = []
        generation += 1
        for c in list {
            switch result {
            case .success(let l): c.resume(returning: l)
            case .failure(let e): c.resume(throwing: e)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        Task { @MainActor in self.finish(.success(l)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        Task { @MainActor in
            if let cached = self.manager.location, -cached.timestamp.timeIntervalSinceNow < 600, !denied {
                self.finish(.success(cached))
            } else {
                self.finish(.failure(denied ? LocationError.denied : LocationError.unavailable))
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorization = self.manager.authorizationStatus
            if self.manager.authorizationStatus != .notDetermined { self.resumeAuthWaiters() }
        }
    }
}
