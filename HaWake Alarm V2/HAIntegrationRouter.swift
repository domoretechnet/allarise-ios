//
//  HAIntegrationRouter.swift
//  HaWake Alarm V2
//
//  Thin routing singleton that delegates to the active backend (MQTT or HA API).
//  All consumer files call HAIntegrationRouter.shared instead of MQTTManager.shared.
//

import Foundation
import Observation

@Observable
final class HAIntegrationRouter {
    static let shared = HAIntegrationRouter()
    
    private(set) var activeBackend: (any HAIntegrationProtocol)?
    
    private init() {}
    
    // MARK: - Forwarding Observable Properties
    
    var connectionState: HAConnectionState {
        activeBackend?.connectionState ?? .notConfigured
    }
    
    var currentAlarmState: AlarmState {
        activeBackend?.currentAlarmState ?? .idle
    }
    
    var snoozeCount: Int {
        activeBackend?.snoozeCount ?? 0
    }
    
    var activeAlarmIndex: Int? {
        get { activeBackend?.activeAlarmIndex }
        set { activeBackend?.activeAlarmIndex = newValue }
    }
    
    var isConnected: Bool {
        activeBackend?.isConnected ?? false
    }
    
    // MARK: - Activation
    
    /// Activate the MQTT backend. Called at app launch.
    func activate(settings: DeviceSettings) {
        activeBackend?.disconnect()
        activeBackend = MQTTManager.shared
    }
    
    // MARK: - Connection Lifecycle
    
    func connect(settings: DeviceSettings) {
        activeBackend?.connect(settings: settings)
    }
    
    func disconnect() {
        activeBackend?.disconnect()
    }
    
    func forceReconnect(settings: DeviceSettings) {
        activeBackend?.forceReconnect(settings: settings)
    }
    
    // MARK: - Global State Publishing
    
    func publishAlarmState(_ state: AlarmState, settings: DeviceSettings) {
        activeBackend?.publishAlarmState(state, settings: settings)
    }
    
    func publishDashboardButtonAvailability(state: AlarmState, settings: DeviceSettings) {
        activeBackend?.publishDashboardButtonAvailability(state: state, settings: settings)
    }
    
    func publishSnoozeCount(_ count: Int, settings: DeviceSettings) {
        activeBackend?.publishSnoozeCount(count, settings: settings)
    }
    
    func publishSnoozesRemaining(_ remaining: Int, settings: DeviceSettings) {
        activeBackend?.publishSnoozesRemaining(remaining, settings: settings)
    }
    
    func publishActiveAlarmIndex(_ index: Int?, settings: DeviceSettings) {
        activeBackend?.publishActiveAlarmIndex(index, settings: settings)
    }
    
    func publishActiveAlarmName(_ name: String?, settings: DeviceSettings) {
        activeBackend?.publishActiveAlarmName(name, settings: settings)
    }
    
    func publishActiveAlarmMission(_ mission: String, settings: DeviceSettings) {
        activeBackend?.publishActiveAlarmMission(mission, settings: settings)
    }
    
    func publishActiveAlarmDays(_ days: String, settings: DeviceSettings) {
        activeBackend?.publishActiveAlarmDays(days, settings: settings)
    }
    
    func publishActiveAlarmFireTime(_ date: Date?, settings: DeviceSettings) {
        activeBackend?.publishActiveAlarmFireTime(date, settings: settings)
    }
    
    func publishActiveAlarmSnoozeFireTime(_ date: Date?, settings: DeviceSettings) {
        activeBackend?.publishActiveAlarmSnoozeFireTime(date, settings: settings)
    }

    func publishActiveAlarmSound(_ sound: String?, settings: DeviceSettings) {
        activeBackend?.publishActiveAlarmSound(sound, settings: settings)
    }

    func publishActiveAlarmVolume(_ volume: Double?, settings: DeviceSettings) {
        activeBackend?.publishActiveAlarmVolume(volume, settings: settings)
    }

    func publishActiveAlarmVibrate(_ enabled: Bool?, settings: DeviceSettings) {
        activeBackend?.publishActiveAlarmVibrate(enabled, settings: settings)
    }

    func publishActiveAlarmFadeIn(_ enabled: Bool?, settings: DeviceSettings) {
        activeBackend?.publishActiveAlarmFadeIn(enabled, settings: settings)
    }

    func publishNextAlarmName(_ name: String?, settings: DeviceSettings) {
        activeBackend?.publishNextAlarmName(name, settings: settings)
    }
    
    func publishNextAlarmFireTime(_ date: Date?, settings: DeviceSettings) {
        activeBackend?.publishNextAlarmFireTime(date, settings: settings)
    }
    
    func publishTotalAlarmCount(_ count: Int, settings: DeviceSettings) {
        activeBackend?.publishTotalAlarmCount(count, settings: settings)
    }
    
    func publishEnabledAlarmCount(_ count: Int, settings: DeviceSettings) {
        activeBackend?.publishEnabledAlarmCount(count, settings: settings)
    }
    
    func publishDisabledAlarmCount(_ count: Int, settings: DeviceSettings) {
        activeBackend?.publishDisabledAlarmCount(count, settings: settings)
    }

    func publishSleepSoundVolume(_ volume: Double, settings: DeviceSettings) {
        activeBackend?.publishSleepSoundVolume(volume, settings: settings)
    }

    func publishSleepSoundName(_ name: String, settings: DeviceSettings) {
        activeBackend?.publishSleepSoundName(name, settings: settings)
    }

    func publishSystemVolume(_ volume: Double, settings: DeviceSettings) {
        activeBackend?.publishSystemVolume(volume, settings: settings)
    }
    
    func publishBrokerConnectionType(_ type: String, settings: DeviceSettings) {
        activeBackend?.publishBrokerConnectionType(type, settings: settings)
    }
    
    func publishAppVersion(settings: DeviceSettings) {
        activeBackend?.publishAppVersion(settings: settings)
    }
    
    func publishMediaAlertVolume(_ volume: Double, settings: DeviceSettings) {
        activeBackend?.publishMediaAlertVolume(volume, settings: settings)
    }
    
    func publishAlertVibrationEnabled(_ enabled: Bool, settings: DeviceSettings) {
        activeBackend?.publishAlertVibrationEnabled(enabled, settings: settings)
    }
    
    func publishAlertLoopMedia(_ enabled: Bool, settings: DeviceSettings) {
        activeBackend?.publishAlertLoopMedia(enabled, settings: settings)
    }
    
    func publishAlertLoopDelay(_ seconds: Double, settings: DeviceSettings) {
        activeBackend?.publishAlertLoopDelay(seconds, settings: settings)
    }
    
    func publishAlertDefaultSound(_ soundID: String, settings: DeviceSettings) {
        activeBackend?.publishAlertDefaultSound(soundID, settings: settings)
    }

    func publishAppPersistence(_ enabled: Bool, settings: DeviceSettings) {
        activeBackend?.publishAppPersistence(enabled, settings: settings)
    }

    /// The raw three-way mode, companion to the effective on/off topic above.
    func publishAppPersistenceMode(_ mode: AppPersistenceMode, settings: DeviceSettings) {
        activeBackend?.publishAppPersistenceMode(mode, settings: settings)
    }
    
    // MARK: - Sleep/Wake State Publishing
    
    func publishUserState(_ state: String, settings: DeviceSettings) {
        activeBackend?.publishUserState(state, settings: settings)
    }
    
    func publishWakeAlarmName(_ name: String, settings: DeviceSettings) {
        activeBackend?.publishWakeAlarmName(name, settings: settings)
    }
    
    func publishDayStartedAt(_ timestamp: String, settings: DeviceSettings) {
        activeBackend?.publishDayStartedAt(timestamp, settings: settings)
    }

    /// Slept-through alarms for today (al-bee.5). No-op when no backend is
    /// active, exactly like every other publish here.
    func publishSleptThroughToday(_ report: SleptThroughReport, settings: DeviceSettings) {
        activeBackend?.publishSleptThroughToday(report, settings: settings)
    }
    
    // MARK: - Per-Alarm State Publishing
    
    func publishPerAlarmState(alarm: Alarm, sortOrder: Int = 0, settings: DeviceSettings) {
        activeBackend?.publishPerAlarmState(alarm: alarm, sortOrder: sortOrder, settings: settings)
    }
    
    func publishPerAlarmStateTransition(alarmIndex: Int, state: AlarmState, snoozeAllowed: Bool, settings: DeviceSettings) {
        activeBackend?.publishPerAlarmStateTransition(alarmIndex: alarmIndex, state: state, snoozeAllowed: snoozeAllowed, settings: settings)
    }
    
    func publishPerAlarmSnoozesRemaining(alarmIndex: Int, remaining: Int, settings: DeviceSettings) {
        activeBackend?.publishPerAlarmSnoozesRemaining(alarmIndex: alarmIndex, remaining: remaining, settings: settings)
    }
    
    func publishPerAlarmSnoozeFireTime(alarmIndex: Int, snoozeUntil: Date?, settings: DeviceSettings) {
        activeBackend?.publishPerAlarmSnoozeFireTime(alarmIndex: alarmIndex, snoozeUntil: snoozeUntil, settings: settings)
    }
    
    // MARK: - Arm Button
    
    func requestArmStateChange(_ armed: Bool, settings: DeviceSettings) {
        activeBackend?.requestArmStateChange(armed, settings: settings)
    }
    
    func publishArmCustomCommand(_ command: String, settings: DeviceSettings) {
        activeBackend?.publishArmCustomCommand(command, settings: settings)
    }
    
    // MARK: - Availability

    func publishOnlineState(settings: DeviceSettings) {
        activeBackend?.publishOnlineState(settings: settings)
    }

    // MARK: - Sound Inventory

    func publishAvailableSleepSounds(settings: DeviceSettings) {
        activeBackend?.publishAvailableSleepSounds(settings: settings)
    }

    func publishAvailableAlarmSounds(settings: DeviceSettings) {
        activeBackend?.publishAvailableAlarmSounds(settings: settings)
    }

    // MARK: - Radio

    func publishRadioFavorites(settings: DeviceSettings) {
        activeBackend?.publishRadioFavorites(settings: settings)
    }

    func publishRadioState(settings: DeviceSettings) {
        activeBackend?.publishRadioState(settings: settings)
    }

    // MARK: - Bulk State Publishing
    
    func publishCurrentAlarmState(alarms: [Alarm], settings: DeviceSettings) {
        activeBackend?.publishCurrentAlarmState(alarms: alarms, settings: settings)
    }
    
    // MARK: - Utility
    
    func isSnoozeAllowedForAlarm(_ alarm: Alarm, snoozesRemaining: Int, settings: DeviceSettings) -> Bool {
        activeBackend?.isSnoozeAllowedForAlarm(alarm, snoozesRemaining: snoozesRemaining, settings: settings) ?? false
    }
    
    func mqttLog(_ message: String) {
        activeBackend?.mqttLog(message)
    }
    
    func publish(topic: String, payload: Any, retain: Bool = false) {
        activeBackend?.publish(topic: topic, payload: payload, retain: retain)
    }
    
    func publish(topic: String, payload: Any, retain: Bool = false, onAck: @escaping () -> Void) {
        activeBackend?.publish(topic: topic, payload: payload, retain: retain, onAck: onAck)
    }
}
