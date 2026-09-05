//
//  AlarmScheduler.swift
//  HaWake Alarm V2
//
//  Created by Bryan on 3/8/26.
//

import Foundation

protocol AlarmScheduler {
    func scheduleAlarm(_ alarm: Alarm, delay: TimeInterval) async
    func cancelAlarm(_ alarm: Alarm) async
    func cancelAllAlarms() async
}

extension AlarmScheduler {
    /// Default: no delay
    func scheduleAlarm(_ alarm: Alarm) async {
        await scheduleAlarm(alarm, delay: 0)
    }
}
