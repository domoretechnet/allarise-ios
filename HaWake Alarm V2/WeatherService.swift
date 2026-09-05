//
//  WeatherService.swift
//  HaWake Alarm V2
//
//  Singleton wrapper around Apple WeatherKit + CLLocationManager.
//  Fetches current conditions and a daily forecast for the user's location.
//

import CoreLocation
import Foundation
import MapKit
import Observation
import WeatherKit

enum WeatherState: Sendable {
    case idle
    case loading
    case loaded(current: CurrentWeather, daily: Forecast<DayWeather>)
    case failed(String)
    case noLocation
}

@MainActor @Observable
final class HaWakeWeatherService: NSObject, CLLocationManagerDelegate {
    static let shared = HaWakeWeatherService()

    var state: WeatherState = .idle
    var attribution: WeatherAttribution?
    var locationName: String?

    private let locationManager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private let service = WeatherKit.WeatherService.shared

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    // MARK: - Public

    /// Loads just the WeatherKit attribution (Apple Weather mark + legal page URL) without
    /// a location or weather query. Lets us display the required attribution wherever the
    /// weather feature is surfaced (e.g. the alarm editor), not only on the weather screen.
    func loadAttributionIfNeeded() async {
        guard attribution == nil else { return }
        attribution = try? await service.attribution
    }

    func fetchWeather() async {
        if DeviceSettings.shared.debugDisableWeatherAPI {
            state = .failed("Weather API disabled (debug toggle)")
            return
        }
        state = .loading

        let status = locationManager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            state = .noLocation
            return
        }

        do {
            let location = try await requestCurrentLocation()
            // Reverse geocode for city name (fire-and-forget, non-blocking)
            Task {
                if let request = MKReverseGeocodingRequest(location: location),
                   let mapItem = try? await request.mapItems.first {
                    self.locationName = mapItem.addressRepresentations?.cityName
                        ?? mapItem.addressRepresentations?.regionName
                }
            }
            let (current, daily) = try await service.weather(
                for: location,
                including: .current, .daily
            )
            attribution = try? await service.attribution
            state = .loaded(current: current, daily: daily)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Location

    private func requestCurrentLocation() async throws -> CLLocation {
        // Cancel any lingering continuation from a previous call
        if let stale = locationContinuation {
            locationContinuation = nil
            stale.resume(throwing: CancellationError())
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.locationContinuation = continuation
            locationManager.requestLocation()

            // 10-second timeout
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard let pending = self.locationContinuation else { return }
                self.locationContinuation = nil
                pending.resume(throwing: CLError(.geocodeFoundNoResult))
            }
        }
    }

    // MARK: - Continuation helpers

    /// Safely resume the continuation exactly once and nil it out.
    private func resumeContinuation(with result: Result<CLLocation, Error>) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        continuation.resume(with: result)
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.resumeContinuation(with: .success(location))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.resumeContinuation(with: .failure(error))
        }
    }
}
