//
//  WatchHapticManager.swift
//  HaWake-Alarm-V2 Watch App
//
//  Tracks alarm active state for the Watch UI.
//  Actual haptic/alert delivery is handled via UNUserNotificationCenter
//  (posted when the WatchConnectivity message arrives), which works reliably
//  even when the Watch app is backgrounded.
//

import Combine
import Foundation
import WatchKit

@MainActor
final class WatchHapticManager: NSObject, ObservableObject {
    static let shared = WatchHapticManager()

    @Published private(set) var isVibrating = false
    @Published private(set) var alarmLabel: String = ""

    private override init() {}

    // MARK: - Start / Stop

    func startVibration(alarmLabel: String) {
        guard !isVibrating else { return }
        print("⌚ WatchHapticManager: alarm active for '\(alarmLabel)'")
        self.alarmLabel = alarmLabel
        isVibrating = true

        // Play an immediate haptic if the app is in the foreground
        WKInterfaceDevice.current().play(.notification)
    }

    func stopVibration() {
        guard isVibrating else { return }
        print("⌚ WatchHapticManager: stopping")
        isVibrating = false
        alarmLabel = ""
    }
}
