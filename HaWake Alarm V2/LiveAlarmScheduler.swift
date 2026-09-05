//
//  LiveAlarmScheduler.swift
//  HaWake Alarm V2
//
//  Created by Bryan on 3/8/26.
//

import Foundation
import UserNotifications
import SwiftData

final class LiveAlarmScheduler: AlarmScheduler {
    static let shared = LiveAlarmScheduler()
    
    /// Fun rotating notification messages. {alarm} is replaced with the alarm label.
    static let alarmNotificationMessages: [(title: String, body: String)] = [
        ("☕ Good morning!", "{alarm} is ready when you are (coffee not included)."),
        ("🛌 Allarise Alert", "{alarm} has entered the \"you should be awake\" phase."),
        ("🧠 Wake Up!", "{alarm} says wake up—your brain will catch up later."),
        ("🐿️ Allarise Alert", "{alarm} is happening whether you like it or not."),
        ("🥱 Rise & Shine!", "{alarm} is here—yawning is allowed but not an excuse."),
        ("📱 Allarise Alert", "{alarm} is trying very hard to get your attention."),
        ("🌅 Rise and shine!", "{alarm} is here courtesy of Allarise."),
    ]
    
    /// Pick a random notification message with the alarm name substituted in.
    static func randomNotificationMessage(alarmLabel: String) -> (title: String, body: String) {
        let template = alarmNotificationMessages.randomElement()!
        return (template.title, template.body.replacingOccurrences(of: "{alarm}", with: alarmLabel))
    }
    
    private init() {}
    
    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            print("Failed to request notification authorization: \(error)")
            return false
        }
    }
    
    @MainActor
    func scheduleAlarm(_ alarm: Alarm, delay: TimeInterval = 0) async {
        guard alarm.isEnabled else {
            await cancelAlarm(alarm)
            return
        }
        
        guard let nextFire = alarm.nextFireDate() else {
            await cancelAlarm(alarm)
            return
        }
        
        let message = Self.randomNotificationMessage(alarmLabel: alarm.label)
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.sound = UNNotificationSound.default
        content.categoryIdentifier = "ALARM_CATEGORY"
        
        // Store alarm ID in userInfo
        content.userInfo = ["alarmID": alarm.stableHash]
        
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: nextFire)
        
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        
        let identifier = "alarm-\(alarm.stableHash)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        
        do {
            try await UNUserNotificationCenter.current().add(request)
            print("Scheduled alarm for: \(nextFire)")
        } catch {
            print("Failed to schedule alarm: \(error)")
        }
    }
    
    @MainActor
    func cancelAlarm(_ alarm: Alarm) async {
        let identifier = "alarm-\(alarm.stableHash)"
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        print("Cancelled alarm: \(identifier)")
    }
    
    func cancelAllAlarms() async {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        print("Cancelled all alarms")
    }
}
