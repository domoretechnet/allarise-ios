//
//  HAIntegrationProtocol.swift
//  HaWake Alarm V2
//
//  Protocol that MQTTManager conforms to.
//  Defines the full public API surface used by consumer files via HAIntegrationRouter.
//

import Foundation

protocol HAIntegrationProtocol: AnyObject {
    
    // MARK: - Observable State
    var connectionState: HAConnectionState { get }
    var currentAlarmState: AlarmState { get }
    var snoozeCount: Int { get }
    var activeAlarmIndex: Int? { get set }
    var isConnected: Bool { get }
    
    // MARK: - Connection Lifecycle
    func connect(settings: DeviceSettings)
    func disconnect()
    func forceReconnect(settings: DeviceSettings)
    
    // MARK: - Global State Publishing
    func publishAlarmState(_ state: AlarmState, settings: DeviceSettings)
    func publishDashboardButtonAvailability(state: AlarmState, settings: DeviceSettings)
    func publishSnoozeCount(_ count: Int, settings: DeviceSettings)
    func publishSnoozesRemaining(_ remaining: Int, settings: DeviceSettings)
    func publishActiveAlarmIndex(_ index: Int?, settings: DeviceSettings)
    func publishActiveAlarmName(_ name: String?, settings: DeviceSettings)
    func publishActiveAlarmMission(_ mission: String, settings: DeviceSettings)
    func publishActiveAlarmDays(_ days: String, settings: DeviceSettings)
    func publishActiveAlarmFireTime(_ date: Date?, settings: DeviceSettings)
    func publishActiveAlarmSnoozeFireTime(_ date: Date?, settings: DeviceSettings)
    func publishActiveAlarmSound(_ sound: String?, settings: DeviceSettings)
    func publishActiveAlarmVolume(_ volume: Double?, settings: DeviceSettings)
    func publishActiveAlarmVibrate(_ enabled: Bool?, settings: DeviceSettings)
    func publishActiveAlarmFadeIn(_ enabled: Bool?, settings: DeviceSettings)
    func publishNextAlarmName(_ name: String?, settings: DeviceSettings)
    func publishNextAlarmFireTime(_ date: Date?, settings: DeviceSettings)
    func publishTotalAlarmCount(_ count: Int, settings: DeviceSettings)
    func publishEnabledAlarmCount(_ count: Int, settings: DeviceSettings)
    func publishDisabledAlarmCount(_ count: Int, settings: DeviceSettings)
    func publishSleepSoundVolume(_ volume: Double, settings: DeviceSettings)
    func publishSleepSoundName(_ name: String, settings: DeviceSettings)
    func publishSystemVolume(_ volume: Double, settings: DeviceSettings)
    func publishBrokerConnectionType(_ type: String, settings: DeviceSettings)
    func publishAppVersion(settings: DeviceSettings)
    func publishMediaAlertVolume(_ volume: Double, settings: DeviceSettings)
    func publishAlertVibrationEnabled(_ enabled: Bool, settings: DeviceSettings)
    func publishAlertLoopMedia(_ enabled: Bool, settings: DeviceSettings)
    func publishAlertLoopDelay(_ seconds: Double, settings: DeviceSettings)
    func publishAlertDefaultSound(_ soundID: String, settings: DeviceSettings)
    /// App Persistence (background audio keep-alive) — the setting Home
    /// Assistant can both read and write. See `MQTTManager.publishAppPersistence`.
    /// The Bool topic reports EFFECTIVE residency; the mode topic reports the
    /// chosen three-way setting (on / off / dynamic).
    func publishAppPersistence(_ enabled: Bool, settings: DeviceSettings)
    func publishAppPersistenceMode(_ mode: AppPersistenceMode, settings: DeviceSettings)
    
    // MARK: - Wake State Publishing
    func publishUserState(_ state: String, settings: DeviceSettings)
    func publishWakeAlarmName(_ name: String, settings: DeviceSettings)
    func publishDayStartedAt(_ timestamp: String, settings: DeviceSettings)
    /// Slept-through alarms for the current calendar day (al-bee.5). ADDITIVE:
    /// two new retained sensor topics, no existing topic or state value
    /// changed. An older app never publishes them, so an older or newer HACS
    /// integration sees an absent/unknown sensor rather than an error.
    func publishSleptThroughToday(_ report: SleptThroughReport, settings: DeviceSettings)

    // MARK: - Per-Alarm State Publishing
    func publishPerAlarmState(alarm: Alarm, sortOrder: Int, settings: DeviceSettings)
    func publishPerAlarmStateTransition(alarmIndex: Int, state: AlarmState, snoozeAllowed: Bool, settings: DeviceSettings)
    func publishPerAlarmSnoozesRemaining(alarmIndex: Int, remaining: Int, settings: DeviceSettings)
    func publishPerAlarmSnoozeFireTime(alarmIndex: Int, snoozeUntil: Date?, settings: DeviceSettings)
    
    // MARK: - Arm Button
    /// Request an arm state change. HA is the source of truth — this publishes a
    /// non-retained request to arm/command; HA confirms by publishing retained to arm/state.
    func requestArmStateChange(_ armed: Bool, settings: DeviceSettings)
    func publishArmCustomCommand(_ command: String, settings: DeviceSettings)
    
    // MARK: - Availability
    func publishOnlineState(settings: DeviceSettings)

    // MARK: - Sound Inventory
    func publishAvailableSleepSounds(settings: DeviceSettings)
    /// Alarm tones (bundled + custom), so HA can offer a dropdown for the
    /// `sound` field instead of a free-text box.
    func publishAvailableAlarmSounds(settings: DeviceSettings)

    // MARK: - Radio
    /// Favourited stations, so HA can offer a dropdown instead of hardcoding names.
    func publishRadioFavorites(settings: DeviceSettings)
    /// Live transport state + current station.
    func publishRadioState(settings: DeviceSettings)

    // MARK: - Bulk State Publishing
    func publishCurrentAlarmState(alarms: [Alarm], settings: DeviceSettings)
    
    // MARK: - Utility
    func isSnoozeAllowedForAlarm(_ alarm: Alarm, snoozesRemaining: Int, settings: DeviceSettings) -> Bool
    func mqttLog(_ message: String)
    
    // MARK: - Low-Level (used by MQTTAlarmHelper extension)
    func publish(topic: String, payload: Any, retain: Bool)
    
    /// Publish with ACK-based completion callback (fires when broker confirms receipt).
    /// For MQTT: fires on QoS 1 ACK. For HA API: fires immediately (webhook is fire-and-forget).
    func publish(topic: String, payload: Any, retain: Bool, onAck: @escaping () -> Void)
}
