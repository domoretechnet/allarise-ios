//
//  HaWake_Alarm_V2App.swift
//  HaWake-Alarm-V2 Watch App
//

import SwiftUI
import UserNotifications
import WatchConnectivity
import WatchKit

@main
struct HaWake_Alarm_V2_Watch_AppApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(WatchHapticManager.shared)
        }
    }
}

// MARK: - Watch App Delegate

final class WatchAppDelegate: NSObject, WKApplicationDelegate, WCSessionDelegate {
    func applicationDidFinishLaunching() {
        // Activate WatchConnectivity
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        print("⌚ Watch WCSession activated")

        // Request notification permission — needed for reliable background alerts
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            print("⌚ Watch notification permission: granted=\(granted) error=\(String(describing: error))")
        }
    }

    // MARK: - WCSessionDelegate

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        print("⌚ Watch WCSession activation complete: state=\(activationState.rawValue)")
    }

    /// Handles real-time messages from the iPhone (Watch app is reachable)
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handlePayload(message)
    }

    /// Handles queued payloads delivered via transferUserInfo
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        // Ignore stale commands (older than 3 minutes)
        if let timestamp = userInfo["timestamp"] as? TimeInterval {
            let age = Date().timeIntervalSince1970 - timestamp
            guard age < 180 else {
                print("⌚ Watch: ignoring stale userInfo (age=\(Int(age))s)")
                return
            }
        }
        handlePayload(userInfo)
    }

    private func handlePayload(_ payload: [String: Any]) {
        guard let command = payload["command"] as? String else { return }
        print("⌚ Watch received command: \(command)")

        switch command {
        case "vibrate":
            let label = payload["alarmLabel"] as? String ?? "Alarm"
            // Post a local notification — works even when the app is suspended,
            // generates a haptic buzz on the Watch face without needing the app active.
            postAlarmNotification(label: label)
            // Also try haptic manager (works when app is already in foreground)
            Task { @MainActor in
                WatchHapticManager.shared.startVibration(alarmLabel: label)
            }
        case "stopVibrate":
            // Cancel all pending alarm notifications
            let ids = (0..<12).map { "watch-alarm-\($0)" }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
            Task { @MainActor in
                WatchHapticManager.shared.stopVibration()
            }
        default:
            print("⌚ Watch: unknown command '\(command)'")
        }
    }

    private func postAlarmNotification(label: String) {
        let center = UNUserNotificationCenter.current()

        // Remove any previous alarm notifications
        center.removeDeliveredNotifications(withIdentifiers: (0..<12).map { "watch-alarm-\($0)" })
        center.removePendingNotificationRequests(withIdentifiers: (0..<12).map { "watch-alarm-\($0)" })

        let content = UNMutableNotificationContent()
        content.title = label
        content.body = "Your alarm is going off"
        content.sound = .default

        // Schedule 12 notifications 8 seconds apart (~96 seconds of repeated haptics)
        for i in 0..<12 {
            let delay = TimeInterval(i * 8 + 1)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            let request = UNNotificationRequest(
                identifier: "watch-alarm-\(i)",
                content: content,
                trigger: trigger
            )
            center.add(request) { error in
                if let error, i == 0 {
                    print("⌚ Watch notification error: \(error)")
                }
            }
        }
        print("⌚ Watch: scheduled 12 alarm notifications for '\(label)'")
    }
}
