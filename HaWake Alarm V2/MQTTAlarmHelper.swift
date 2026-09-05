//
//  MQTTAlarmHelper.swift
//  HaWake Alarm V2
//
//  Helper methods for publishing alarm state to MQTT
//
//  ✅ NOW ACTIVE - Extension for real MQTTManager
//

import Foundation
import SwiftData

extension MQTTManager {
    
    /// Publish all current alarm state to MQTT
    /// Call this when app launches or alarms change
    func publishCurrentAlarmState(alarms: [Alarm], settings: DeviceSettings) {
        print("📡 publishCurrentAlarmState called: isConnected=\(isConnected), alarmCount=\(alarms.count)")
        guard isConnected else {
            print("⚠️ MQTT not connected, skipping state publish")
            return
        }
        
        // CRITICAL: If an alarm is being deleted, bail out entirely.
        // SwiftUI's .onChange(of: alarms) fires synchronously on the same
        // run-loop turn as context.save() after a delete. The @Query results
        // may still contain the deleted object with invalidated backing data.
        // Accessing lazy properties (recurringDays) on such objects crashes.
        guard !MQTTCommandHandler.shared.isSuppressingAlarmAccess else {
            print("⚠️ publishCurrentAlarmState: suppressed (alarm delete in progress)")
            return
        }
        
        // Filter out detached alarms — these have been deleted from SwiftData
        // but may still appear in arrays passed by @Query or iCloud sync.
        // Accessing lazy properties on detached objects causes a fatal crash.
        // MQTT-hidden alarms (Kids Sleep bedtime alarm, al-5a94) are dropped in
        // the same pass: this one filter keeps them out of the counts, the
        // next-alarm sensor, the idle active_* block and the per-alarm loop.
        let alarms = alarms.filter { !$0.isDetached && !$0.excludeFromMQTT }
        
        // One-time migration: label-based slugs → index-based IDs
        if !UserDefaults.standard.bool(forKey: "mqttPerAlarmV3Migrated") {
            migratePerAlarmToIndexBased(alarms: alarms, settings: settings)
            UserDefaults.standard.set(true, forKey: "mqttPerAlarmV3Migrated")
        }
        
        // Separate ephemeral (quick) alarms from regular alarms
        let regularAlarms = alarms.filter { !$0.isEphemeral }
        let quickAlarms = alarms.filter { $0.isEphemeral }

        // Count regular alarms only (quick alarms have their own sensor)
        let enabledAlarms = regularAlarms.filter { $0.isEnabled }
        let disabledCount = regularAlarms.count - enabledAlarms.count

        // Publish alarm counts to Dashboard device (excludes quick alarms)
        publishTotalAlarmCount(regularAlarms.count, settings: settings)
        publishEnabledAlarmCount(enabledAlarms.count, settings: settings)
        publishDisabledAlarmCount(disabledCount, settings: settings)

        // Find next enabled alarm (include quick alarms in next-alarm calculation)
        let allEnabled = alarms.filter { $0.isEnabled }
        let nextAlarm = allEnabled
            .compactMap { alarm -> (alarm: Alarm, date: Date)? in
                guard let date = alarm.nextFireDate() else {
                    print("📡 Alarm '\(alarm.label)' enabled but nextFireDate=nil (recurring=\(alarm.isRecurring), lastFire=\(String(describing: alarm.lastFireDate)))")
                    return nil
                }
                return (alarm, date)
            }
            .min(by: { $0.date < $1.date })
        print("📡 Next alarm calculation: \(alarms.count) total, \(allEnabled.count) enabled, next=\(nextAlarm?.alarm.label ?? "none") at \(nextAlarm?.date.description ?? "n/a")")
        publishNextAlarmName(nextAlarm?.alarm.label, settings: settings)
        publishNextAlarmFireTime(nextAlarm?.date, settings: settings)

        // Publish Quick Alarm dashboard sensor
        publishQuickAlarmState(quickAlarms: quickAlarms, settings: settings)

        // Slept-through count (al-bee.5). Published from the bulk pass as well
        // as from reconciliation so a fresh broker connection — or a Home
        // Assistant restart — gets today's value without waiting for the next
        // foreground. Read-only over the ledger; costs one dictionary read.
        publishSleptThroughToday(UnresolvedRingLedger.shared.report(), settings: settings)

        // If no alarm is currently ringing, publish idle state.
        // Queue-based: fill in the next upcoming alarm's details so the
        // dashboard always shows relevant data rather than all-None.
        if AlarmWindowManager.shared.currentAlarm == nil {
            publishAlarmState(.idle, settings: settings)
            publishSnoozeCount(0, settings: settings)
            publishSnoozesRemaining(0, settings: settings)

            if let next = nextAlarm {
                let alarm = next.alarm
                let s = settings
                publishActiveAlarmIndex(alarm.alarmIndex > 0 ? alarm.alarmIndex : nil, settings: s)
                publishActiveAlarmName(alarm.label, settings: s)
                publishActiveAlarmFireTime(next.date, settings: s)
                publishActiveAlarmSnoozeFireTime(nil, settings: s)
                publishActiveAlarmMission(alarm.mission.type.rawValue.lowercased(), settings: s)
                publishActiveAlarmDays(alarm.isRecurring ? alarm.recurringDays.map { String($0) }.sorted().joined(separator: ",") : "once", settings: s)
                publishActiveAlarmSound(alarm.soundName, settings: s)
                publishActiveAlarmVolume(alarm.effectiveVolumeLevel(settings: s), settings: s)
                publishActiveAlarmVibrate(alarm.effectiveVibrationEnabled(settings: s), settings: s)
                publishActiveAlarmFadeIn(alarm.effectiveFadeInEnabled(settings: s), settings: s)
            } else {
                publishActiveAlarmIndex(nil, settings: settings)
                publishActiveAlarmName(nil, settings: settings)
                publishActiveAlarmFireTime(nil, settings: settings)
                publishActiveAlarmSnoozeFireTime(nil, settings: settings)
                publishActiveAlarmMission("none", settings: settings)
                publishActiveAlarmDays("none", settings: settings)
                publishActiveAlarmSound(nil, settings: settings)
                publishActiveAlarmVolume(nil, settings: settings)
                publishActiveAlarmVibrate(nil, settings: settings)
                publishActiveAlarmFadeIn(nil, settings: settings)
            }
        } else if let ringing = AlarmWindowManager.shared.currentAlarm, !ringing.excludeFromMQTT {
            // Also publish the new detail fields for the currently ringing alarm.
            // (Name/mission/state are published by showAlarm; these new fields are not.)
            let s = settings
            publishActiveAlarmSound(ringing.soundName, settings: s)
            publishActiveAlarmVolume(ringing.effectiveVolumeLevel(settings: s), settings: s)
            publishActiveAlarmVibrate(ringing.effectiveVibrationEnabled(settings: s), settings: s)
            publishActiveAlarmFadeIn(ringing.effectiveFadeInEnabled(settings: s), settings: s)
        }

        // Sort regular alarms the same way the app does (soonest/firing first)
        let sortedRegular = MQTTManager.sortAlarmsForDisplay(regularAlarms)

        // Publish per-alarm state (regular alarms only — quick alarms have no index)
        for (sortOrder, alarm) in sortedRegular.enumerated() {
            publishPerAlarmState(alarm: alarm, sortOrder: sortOrder + 1, settings: settings)
        }

        // Dashboard unskip availability — online if any enabled alarm is currently skipped
        if isConnected {
            let anySkipped = regularAlarms.first(where: { $0.isEnabled && $0.isSkipped }) != nil
            publish(
                topic: "\(settings.mqttTopicPrefix)/\(settings.sanitizedDeviceName)/dashboard/unskip_availability",
                payload: anySkipped ? "online" : "offline",
                retain: settings.mqttPublishRetained
            )
        }

        // Clear stale retained MQTT data for alarm indices that no longer exist.
        let activeIndices = Set(regularAlarms.map(\.alarmIndex).filter { $0 > 0 })

        // Safety guard: if the alarm list looks incomplete relative to the highest
        // index ever assigned, skip the stale purge entirely. A partial @Query result
        // (which happens when MQTTDidConnect fires during a rapid reconnect while
        // SwiftData is still refreshing) would otherwise incorrectly clear retained
        // broker data for alarms that still exist.
        let highestKnownIndex = settings.nextAlarmIndex - 1  // nextAlarmIndex is "next to assign"
        let assignedCount = max(0, highestKnownIndex)
        let presentCount = activeIndices.count
        // Allow the purge only when regularAlarms covers all previously assigned indices
        // (accounting for legitimately deleted alarms — presentCount can be less than
        // assignedCount when alarms have been deleted, but it should never be dramatically
        // lower on a normal call). Use a strict threshold: require at least 80% of the
        // highest-known index to be present. If we see far fewer, SwiftData hasn't fully
        // loaded yet (partial @Query result on rapid reconnect) and we must not purge.
        let threshold = max(1, Int(Double(assignedCount) * 0.8))
        let purgeIsSafe = assignedCount == 0 || presentCount >= threshold
        guard purgeIsSafe else {
            print("⚠️ Skipping stale MQTT purge: only \(presentCount) alarms visible out of \(assignedCount) assigned indices — likely partial SwiftData load")
            return
        }

        // One-time wide purge: covers indices that existed before a SwiftData reset
        // (nextAlarmIndex would have reset to a low value, leaving stale broker data
        // at higher indices that the normal narrow scan would never reach).
        let widePurgeKey = "mqttWideStalePurge_v1"
        if !UserDefaults.standard.bool(forKey: widePurgeKey) {
            for index in 1..<200 {
                if !activeIndices.contains(index) {
                    clearDeletedAlarm(alarmIndex: index, settings: settings)
                }
            }
            UserDefaults.standard.set(true, forKey: widePurgeKey)
        } else {
            // Ongoing: only scan the known range
            let maxIndex = settings.nextAlarmIndex
            for index in 1..<maxIndex {
                if !activeIndices.contains(index) {
                    clearDeletedAlarm(alarmIndex: index, settings: settings)
                }
            }
        }

        print("📡 Published current alarm state: \(alarms.count) total, \(enabledAlarms.count) enabled, \(disabledCount) disabled")
    }
    
    /// One-time migration: assign stable indices to existing alarms,
    /// remove old label-based MQTT entities, and let the normal flow publish new index-based ones.
    private func migratePerAlarmToIndexBased(alarms: [Alarm], settings: DeviceSettings) {
        print("🔄 Starting per-alarm MQTT migration: labels → indices")

        for alarm in alarms {
            // Skip ephemeral (quick) alarms — they don't get per-alarm MQTT entities
            guard !alarm.isEphemeral else { continue }

            // Assign index if not yet assigned
            if alarm.alarmIndex == 0 {
                alarm.alarmIndex = settings.assignNextAlarmIndex()
                print("🔄 Assigned index \(alarm.alarmIndex) to alarm: \(alarm.label)")
            }
        }
        
        print("✅ Per-alarm MQTT migration complete")
    }
}

