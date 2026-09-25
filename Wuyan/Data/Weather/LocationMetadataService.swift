import CoreLocation
import Foundation

@MainActor
final class LocationMetadataService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    func requestLocation() async -> CLLocation? {
        // CLLocationManager 只有一个请求槽位。并发调用时拒绝后续请求，由调用方
        // 在需要时重试；同时设超时，防止权限回调缺失导致永久悬挂。
        guard continuation == nil else { return nil }
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            return nil
        }
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                timeoutTask?.cancel()
                timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.finish(nil)
                }
                manager.requestLocation()
            }
        }, onCancel: {
            Task { @MainActor [weak self] in self?.finish(nil) }
        })
    }

    private func finish(_ location: CLLocation?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume(returning: location)
        continuation = nil
    }

    func geocode(_ location: CLLocation) async -> String {
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
            return "当前位置"
        }
        return placemark.locality ?? placemark.name ?? "当前位置"
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            finish(locations.last)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            finish(nil)
        }
    }
}
