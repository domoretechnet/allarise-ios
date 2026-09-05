//
//  ChargingStateTracker.swift
//  HaWake Alarm V2
//
//  Monitors device charging state changes and persists events
//  for use as a sleep onset signal. Plugging in at night is a
//  strong indicator that the user is going to bed.
//

import Foundation
import UIKit

// MARK: - Data Model

struct ChargingEvent: Codable {
    let timestamp: Date
    let state: ChargingState
    
    enum ChargingState: String, Codable {
        case pluggedIn   // batteryState == .charging || .full
        case unplugged   // batteryState == .unplugged
    }
}

// MARK: - Tracker

@MainActor
final class ChargingStateTracker {
    static let shared = ChargingStateTracker()
    
    private let storageKey = "ChargingStateTracker.events"
    private let rollingWindowDays = 7
    
    private(set) var events: [ChargingEvent] = []
    private var lastKnownState: ChargingEvent.ChargingState?
    
    private init() {
        load()
        startMonitoring()
    }
    
    // MARK: - Monitoring
    
    private func startMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        
        // Record the initial state so there is always a baseline
        recordCurrentState()
        
        // Observe battery state changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(batteryStateChanged),
            name: UIDevice.batteryStateDidChangeNotification,
            object: nil
        )
        
        AppLogger.shared.log(
            "ChargingStateTracker: monitoring started, initial state=\(lastKnownState?.rawValue ?? "unknown")",
            category: .general
        )
    }
    
    @objc private func batteryStateChanged(_ notification: Notification) {
        Task { @MainActor in
            recordCurrentState()
        }
    }
    
    private func recordCurrentState() {
        let batteryState = UIDevice.current.batteryState
        let newState: ChargingEvent.ChargingState?
        
        switch batteryState {
        case .charging, .full:
            newState = .pluggedIn
        case .unplugged:
            newState = .unplugged
        case .unknown:
            newState = nil
        @unknown default:
            newState = nil
        }
        
        guard let newState, newState != lastKnownState else { return }
        
        let event = ChargingEvent(timestamp: Date(), state: newState)
        events.append(event)
        lastKnownState = newState
        pruneOldEntries()
        save()
        
        AppLogger.shared.log(
            "ChargingStateTracker: \(newState.rawValue) at \(event.timestamp.formatted(date: .omitted, time: .standard))",
            category: .general
        )
    }
    
    // MARK: - Query API
    
    /// Returns the most recent pluggedIn event before the given date,
    /// within the lookback window. This is the sleep onset hint.
    func lastPluggedIn(before date: Date, lookbackHours: Double) -> Date? {
        let cutoff = date.addingTimeInterval(-lookbackHours * 3600)
        return events
            .filter { $0.state == .pluggedIn && $0.timestamp >= cutoff && $0.timestamp < date }
            .last?.timestamp
    }
    
    /// Returns the most recent unplugged event before the given date.
    /// This is a wake hint (user grabs phone off charger).
    func lastUnplugged(before date: Date, lookbackHours: Double) -> Date? {
        let cutoff = date.addingTimeInterval(-lookbackHours * 3600)
        return events
            .filter { $0.state == .unplugged && $0.timestamp >= cutoff && $0.timestamp < date }
            .last?.timestamp
    }
    
    /// All events within a time range (for CSV export)
    func events(from start: Date, to end: Date) -> [ChargingEvent] {
        events.filter { $0.timestamp >= start && $0.timestamp <= end }
    }
    
    // MARK: - Persistence
    
    private func save() {
        do {
            let data = try JSONEncoder().encode(events)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            print("[CHARGING] Failed to save events: \(error)")
        }
    }
    
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        do {
            events = try JSONDecoder().decode([ChargingEvent].self, from: data)
            lastKnownState = events.last?.state
            pruneOldEntries()
            print("[CHARGING] Loaded \(events.count) events from storage")
        } catch {
            print("[CHARGING] Failed to load events: \(error)")
            events = []
        }
    }
    
    private func pruneOldEntries() {
        let cutoff = Date().addingTimeInterval(-Double(rollingWindowDays) * 24 * 3600)
        let before = events.count
        events.removeAll { $0.timestamp < cutoff }
        let pruned = before - events.count
        if pruned > 0 {
            print("[CHARGING] Pruned \(pruned) old events (>\(rollingWindowDays) days)")
        }
    }
}
