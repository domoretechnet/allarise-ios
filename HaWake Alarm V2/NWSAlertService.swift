//
//  NWSAlertService.swift
//  HaWake Alarm V2
//
//  Polls the NWS (National Weather Service) API for active severe weather
//  alerts at user-defined locations. Fires alarm-style alerts (mirroring
//  the MQTT security alert system) when critical weather events are detected.
//
//  HIGHLY EXPERIMENTAL
//

import Foundation
import UIKit
import CoreLocation
import AVFoundation
import UserNotifications

@MainActor @Observable
final class NWSAlertService: NSObject {
    static let shared = NWSAlertService()

    /// Whether the service is actively polling.
    private(set) var isPolling = false
    /// Last poll time per location (for UI display).
    private(set) var lastPollTimes: [UUID: Date] = [:]
    /// Last error per location (for UI display).
    private(set) var lastErrors: [UUID: String] = [:]
    /// Currently active NWS alerts (for UI display).
    private(set) var activeAlerts: [NWSAlertFeature] = []

    private var pollTimer: Timer?
    private var seenAlertIDs: Set<String> = []
    private let locationManager = CLLocationManager()
    private var currentLocation: CLLocation?
    private var lastLocationRequestAt: Date = .distantPast

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = [
            "User-Agent": "AllAriseAlarm/1.0 (iOS weather alert monitoring)",
            "Accept": "application/geo+json"
        ]
        return URLSession(configuration: config)
    }()

    private static let pollInterval: TimeInterval = 30
    /// How often to refresh the cached GPS fix. Polls between refreshes reuse
    /// the last known coordinate — a one-shot fix every few minutes is plenty
    /// for county-scale NWS alert zones.
    private static let locationRefreshInterval: TimeInterval = 300
    private static let expiryFormatter = ISO8601DateFormatter()

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        // Load persisted seen IDs
        seenAlertIDs = DeviceSettings.shared.nwsSeenAlertIDs
    }

    // MARK: - Start / Stop

    /// Starts (or re-arms) polling. Safe to call repeatedly: the poll timer is
    /// always recreated, so a stale timer left over from a prior session or a
    /// background suspension is replaced rather than leaving `isPolling` true
    /// while nothing actually polls.
    func start() {
        isPolling = true

        // Request location if any monitored location uses current location
        let locations = DeviceSettings.shared.nwsMonitoredLocations
        if locations.contains(where: { $0.useCurrentLocation }) {
            locationManager.requestWhenInUseAuthorization()
            requestLocationFixIfNeeded()
        }

        // (Re)arm the poll timer. Added to the common run-loop mode so it keeps
        // firing during UI tracking (e.g. while scrolling), matching the alarm
        // and keep-alive timers elsewhere in the app.
        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollAllLocations()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // Poll immediately so fresh data is available without waiting a cycle.
        Task { await pollAllLocations() }

        print("🌩️ NWS Alert Service started")
    }

    func stop() {
        isPolling = false
        pollTimer?.invalidate()
        pollTimer = nil
        locationManager.stopUpdatingLocation()
        print("🌩️ NWS Alert Service stopped")
    }

    // MARK: - Polling

    private func pollAllLocations() async {
        let locations = DeviceSettings.shared.nwsMonitoredLocations
        guard !locations.isEmpty else { return }

        // Refresh the cached GPS fix if it's due (one-shot, throttled)
        if locations.contains(where: { $0.useCurrentLocation }) {
            requestLocationFixIfNeeded()
        }

        // Drop active alerts whose expiry has passed so the list stays bounded
        pruneExpiredActiveAlerts()

        // Prune expired seen IDs periodically (keep last 500)
        if seenAlertIDs.count > 500 {
            seenAlertIDs = Set(Array(seenAlertIDs).suffix(200))
            DeviceSettings.shared.nwsSeenAlertIDs = seenAlertIDs
        }

        for location in locations {
            do {
                let alerts = try await fetchAlerts(for: location)
                lastPollTimes[location.id] = Date()
                lastErrors.removeValue(forKey: location.id)
                for alert in alerts {
                    processAlert(alert, location: location)
                }
            } catch {
                lastErrors[location.id] = error.localizedDescription
                print("⚠️ NWS poll failed for '\(location.name)': \(error.localizedDescription)")
            }
        }
    }

    /// Requests a single location fix at most every `locationRefreshInterval`.
    /// The result lands in `currentLocation` via the delegate; polls in between
    /// use that cached coordinate. If no fix has arrived yet, `fetchAlerts`
    /// throws `noCurrentLocation` for current-location entries as before.
    private func requestLocationFixIfNeeded() {
        guard Date().timeIntervalSince(lastLocationRequestAt) >= Self.locationRefreshInterval else { return }
        lastLocationRequestAt = Date()
        locationManager.requestLocation()
    }

    private func pruneExpiredActiveAlerts() {
        guard !activeAlerts.isEmpty else { return }
        let now = Date()
        activeAlerts.removeAll { alert in
            guard let expires = alert.properties.expires,
                  let expiry = Self.expiryFormatter.date(from: expires) else { return false }
            return expiry < now
        }
    }

    private func fetchAlerts(for location: NWSMonitoredLocation) async throws -> [NWSAlertFeature] {
        let lat: Double
        let lon: Double

        if location.useCurrentLocation {
            guard let current = currentLocation else {
                throw NWSError.noCurrentLocation
            }
            lat = current.coordinate.latitude
            lon = current.coordinate.longitude
        } else {
            lat = location.latitude
            lon = location.longitude
        }

        let urlString = "https://api.weather.gov/alerts/active?point=\(lat),\(lon)"
        guard let url = URL(string: urlString) else {
            throw NWSError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        if let httpResponse = response as? HTTPURLResponse {
            guard (200...299).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 503 {
                    throw NWSError.rateLimited
                }
                throw NWSError.httpError(httpResponse.statusCode)
            }
        }

        let decoded = try JSONDecoder().decode(NWSAlertResponse.self, from: data)
        return decoded.features
    }

    // MARK: - Alert Processing

    private func processAlert(_ alert: NWSAlertFeature, location: NWSMonitoredLocation) {
        guard let event = alert.properties.event else { return }
        let alertID = alert.properties.id ?? alert.id

        // Dedup: skip if already seen
        guard !seenAlertIDs.contains(alertID) else { return }

        // Match to a known category
        guard let category = NWSAlertCategory.category(forEvent: event) else {
            // Unknown event type — skip
            return
        }

        // Check if this category is enabled for this location
        let catSettings = location.settings(for: category)
        guard catSettings.enabled else { return }

        // Mark as seen
        seenAlertIDs.insert(alertID)
        DeviceSettings.shared.nwsSeenAlertIDs = seenAlertIDs

        // Build alert content
        let title = "⚠️ \(event)"
        let headline = alert.properties.headline ?? event
        let description = alert.properties.description ?? ""
        let area = alert.properties.areaDesc ?? ""
        let message = [headline, "", area, "", description]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        print("🚨 NWS Alert: \(event) for '\(location.name)' — \(headline)")

        // Track active alerts for UI
        activeAlerts.append(alert)

        // Fire the alert
        Task {
            await fireAlert(title: title, message: message, category: category, settings: catSettings)
        }
    }

    // MARK: - Alert Firing (mirrors MQTTCommandHandler.handleSecurityAlert)

    private func fireAlert(title: String, message: String, category: NWSAlertCategory, settings catSettings: NWSAlertCategorySettings) async {
        let soundID = catSettings.soundID.isEmpty
            ? (DeviceSettings.shared.alertDefaultSound.isEmpty
                ? AlarmSoundManager.shared.getDefaultSound().id
                : DeviceSettings.shared.alertDefaultSound)
            : catSettings.soundID
        let alarmID = MQTTCommandHandler.alertAlarmID(title: title)

        // 1. Store alert info for the alarm display
        let store = PendingAlarmStore.shared
        store.storeAlertInfo(alarmID: alarmID, title: title, message: message)
        store.pendingAlarm = PendingAlarmStore.PendingAlarmInfo(
            alarmID: alarmID,
            label: title,
            missionType: .alert,
            soundID: soundID,
            volumeLevel: catSettings.volume
        )
        store.setPendingAlarmFull(
            alarmID: alarmID,
            label: title,
            missionType: MissionType.alert.rawValue,
            soundID: soundID,
            volumeLevel: catSettings.volume
        )

        // 2. Configure audio session
        do {
            try AppAudioSession.setCategory(.playAndRecord, mode: .default, options: AppAudioSession.alarmFireCategoryOptions())
            try AppAudioSession.setActive(true)
        } catch {
            print("❌ NWS alert audio session setup failed: \(error)")
        }

        await VolumeManager.shared.ensureReady()

        let effectiveVolume = min(max(catSettings.volume, 0.0), 1.0)
        let fadeInEnabled = catSettings.fadeInEnabled
        let fadeInDuration = TimeInterval(catSettings.fadeInDuration)

        // 3. Unlock sound player and play
        AlarmSoundPlayer.shared.unlock()
        if fadeInEnabled {
            VolumeManager.shared.prepareForFadeIn(to: Float(effectiveVolume))
        } else {
            VolumeManager.shared.setSystemVolume(to: Float(effectiveVolume))
        }
        await AlarmSoundPlayer.shared.play(soundID: soundID, initialVolume: fadeInEnabled ? 0.0 : 1.0)
        if fadeInEnabled {
            try? await Task.sleep(for: .seconds(1))
            VolumeManager.shared.startPlayerFadeIn(duration: fadeInDuration)
        }

        // 4. Show alarm UI or fire notification
        let appState = UIApplication.shared.applicationState

        if appState == .active {
            AlarmWindowManager.shared.showAlarm(
                alarmID: alarmID,
                label: title,
                missionType: .alert,
                soundID: soundID
            )
        } else {
            // Background: fire notification + show alarm
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message.prefix(200).description
            content.categoryIdentifier = "NWS_ALERT"

            if let sound = AlarmSoundManager.shared.getSound(id: soundID) {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(sound.id + ".wav"))
            } else {
                content.sound = .default
            }

            content.userInfo = [
                "alertAlarmID": alarmID,
                "soundID": soundID,
                "volumeLevel": catSettings.volume,
                "playSound": true
            ]

            let request = UNNotificationRequest(
                identifier: "nws-alert-\(alarmID)",
                content: content,
                trigger: nil
            )

            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                print("❌ Failed to schedule NWS alert notification: \(error)")
            }

            AlarmWindowManager.shared.showAlarm(
                alarmID: alarmID,
                label: title,
                missionType: .alert,
                soundID: soundID
            )
        }

        AppLogger.shared.log("NWS alert fired: \(title)", category: .alarm)
    }

    /// Clear all seen alert IDs (for testing).
    func clearSeenAlerts() {
        seenAlertIDs.removeAll()
        DeviceSettings.shared.nwsSeenAlertIDs = []
        activeAlerts.removeAll()
    }
}

// MARK: - CLLocationManagerDelegate

extension NWSAlertService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.currentLocation = location
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("⚠️ NWS location manager error: \(error)")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        Task { @MainActor in
            guard self.isPolling else { return }
            guard DeviceSettings.shared.nwsMonitoredLocations.contains(where: { $0.useCurrentLocation }) else { return }
            self.lastLocationRequestAt = Date()
            self.locationManager.requestLocation()
        }
    }
}

// MARK: - Errors

enum NWSError: LocalizedError {
    case noCurrentLocation
    case invalidURL
    case rateLimited
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .noCurrentLocation: return "Current location unavailable"
        case .invalidURL: return "Invalid API URL"
        case .rateLimited: return "NWS API rate limited — will retry"
        case .httpError(let code): return "HTTP error \(code)"
        }
    }
}
