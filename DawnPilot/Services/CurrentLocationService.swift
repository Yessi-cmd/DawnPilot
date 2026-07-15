import CoreLocation
import Foundation
import MapKit

struct ResolvedCurrentLocation: Sendable {
    let latitude: Double
    let longitude: Double
    let displayName: String
    let timeZoneIdentifier: String
}

private struct ResolvedPlace: Sendable {
    let displayName: String
    let timeZoneIdentifier: String?
}

enum CurrentLocationError: LocalizedError {
    case permissionDenied
    case permissionRestricted
    case requestInProgress
    case unavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "定位权限已关闭。请到系统设置中的“晨航 > 位置”，允许“使用 App 时”访问位置后重试。"
        case .permissionRestricted:
            "此设备限制了定位权限，暂时无法自动获取当前位置。你仍可在高级设置中手动填写坐标。"
        case .requestInProgress:
            "正在获取当前位置，请稍候。"
        case .unavailable:
            "暂时无法获取当前位置。请确认系统定位服务已开启，并在室外或网络良好时重试。"
        }
    }
}

@MainActor
final class CurrentLocationService: NSObject {
    private let manager: CLLocationManager
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var isLocationRequestActive = false

    override init() {
        manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        super.init()
        manager.delegate = self
    }

    func resolveCurrentLocation() async throws -> ResolvedCurrentLocation {
        let location = try await requestLocation()
        let place = await reverseGeocode(location)
        let coordinate = location.coordinate

        return ResolvedCurrentLocation(
            latitude: roundedForWeather(coordinate.latitude),
            longitude: roundedForWeather(coordinate.longitude),
            displayName: place?.displayName ?? "当前位置",
            timeZoneIdentifier: place?.timeZoneIdentifier ?? TimeZone.current.identifier
        )
    }

    private func requestLocation() async throws -> CLLocation {
        guard locationContinuation == nil else {
            throw CurrentLocationError.requestInProgress
        }

        return try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
            continueAfterAuthorizationChange()
        }
    }

    private func continueAfterAuthorizationChange() {
        guard locationContinuation != nil else { return }

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            guard !isLocationRequestActive else { return }
            isLocationRequestActive = true
            manager.requestLocation()
        case .denied:
            finishLocationRequest(with: .failure(CurrentLocationError.permissionDenied))
        case .restricted:
            finishLocationRequest(with: .failure(CurrentLocationError.permissionRestricted))
        @unknown default:
            finishLocationRequest(with: .failure(CurrentLocationError.unavailable))
        }
    }

    private func finishLocationRequest(with result: Result<CLLocation, Error>) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        isLocationRequestActive = false
        continuation.resume(with: result)
    }

    private func reverseGeocode(_ location: CLLocation) async -> ResolvedPlace? {
        await withCheckedContinuation { continuation in
            guard let request = MKReverseGeocodingRequest(location: location) else {
                continuation.resume(returning: nil)
                return
            }

            request.preferredLocale = Locale(identifier: "zh-Hans_CN")
            request.getMapItems { [request] mapItems, error in
                guard !request.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                guard error == nil, let mapItem = mapItems?.first else {
                    continuation.resume(returning: nil)
                    return
                }

                let representations = mapItem.addressRepresentations
                let candidates = [
                    representations?.cityWithContext(.automatic),
                    representations?.cityName,
                    mapItem.address?.shortAddress,
                    mapItem.name
                ]
                let displayName = candidates
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? "当前位置"

                continuation.resume(returning: ResolvedPlace(
                    displayName: displayName,
                    timeZoneIdentifier: mapItem.timeZone?.identifier
                ))
            }
        }
    }

    private func roundedForWeather(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }
}

extension CurrentLocationService: @MainActor CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        continueAfterAuthorizationChange()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last(where: {
            $0.horizontalAccuracy >= 0 && CLLocationCoordinate2DIsValid($0.coordinate)
        }) else {
            finishLocationRequest(with: .failure(CurrentLocationError.unavailable))
            return
        }

        finishLocationRequest(with: .success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let locationError = error as? CLError
        let resolvedError: CurrentLocationError = locationError?.code == .denied
            ? .permissionDenied
            : .unavailable
        finishLocationRequest(with: .failure(resolvedError))
    }
}
