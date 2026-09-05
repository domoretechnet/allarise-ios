//
//  MQTTManager.swift
//  HaWake Alarm V2
//
//  Full MQTT integration for Home Assistant
//  Handles automatic broker switching and state publishing. Home Assistant
//  discovery is owned by the HACS integration — this file publishes state and
//  subscribes to `homeassistant/status`, never a discovery config topic.
//
//  ✅ NOW ENABLED - Real MQTT using CocoaMQTT

import Foundation
import Observation
import CocoaMQTT
import UIKit
import AVFoundation

@Observable
final class MQTTManager: HAIntegrationProtocol, CocoaMQTTDelegate {
    static let shared = MQTTManager()
    
    private var client: CocoaMQTT?
    private(set) var connectionState: MQTTConnectionState = .disconnected
    private(set) var currentAlarmState: AlarmState = .idle
    
    private(set) var snoozeCount = 0
    /// Index of the alarm currently active (ringing/snoozed). Used by global skip/kill_snoozed commands.
    var activeAlarmIndex: Int?
    private var lastUsedHost: String?
    private var reconnectTimer: Timer?
    /// Exponential backoff steps for reconnect attempts; capped at the last value.
    private let reconnectBackoffIntervals: [TimeInterval] = [5, 10, 30, 120, 300]
    private var reconnectBackoffIndex = 0
    private var isIntentionalDisconnect = false
    private var connectivityCheckTimer: Timer?
    private var connectionTimeoutTimer: Timer?
    private var lastPongTime: Date = Date()
    
    /// Callbacks waiting for broker ACK (QoS 1 publish confirmation)
    private var pendingPublishCallbacks: [UInt16: () -> Void] = [:]

    // System volume monitoring — debounced so hardware button presses don't flood MQTT
    @ObservationIgnored private var systemVolumeObserver: NSKeyValueObservation?
    @ObservationIgnored private var systemVolumeDebounce: DispatchWorkItem?
    
    /// Log a message to console and the unified app log.
    func mqttLog(_ message: String) {
        print(message)
        AppLogger.shared.log(message, category: .mqtt)
    }
    
    var isConnected: Bool {
        if case .connected = connectionState {
            return true
        }
        return false
    }
    
    private init() {
        // Monitor network changes
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NetworkChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleNetworkChange()
        }
        
        // Monitor app returning to foreground — reconnect MQTT if needed
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppWillEnterForeground()
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppDidBecomeActive()
        }
        
        // Monitor audio session interruptions that could kill background audio
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioInterruption(notification)
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        reconnectTimer?.invalidate()
        connectivityCheckTimer?.invalidate()
    }
    
    /// Switch payloads fail closed: anything that is not the accepted "ON" turns
    /// the feature off. That stays — it is the safe direction. What was missing was
    /// any trace of it, so a typo'd automation ("on", "true", "1") looked like a
    /// working OFF command. This logs the topic and the payload, then the caller
    /// applies the fail-closed behaviour unchanged.
    func warnIfUnrecognizedSwitchPayload(_ payload: String, topic: String) {
        let normalized = payload.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized != "ON", normalized != "OFF" else { return }
        mqttLog("⚠️ Unrecognized switch payload on \(topic): '\(payload)' — treated as OFF (fail-closed). Expected \"ON\" or \"OFF\".")
    }

    // MARK: - Client Identity

    /// UserDefaults key holding this install's random client-ID suffix.
    static let clientIDSuffixKey = "mqttClientIDSuffix"

    /// The per-install random suffix, generated once and then reused forever so
    /// the client ID is stable across launches (a changing ID would leave stale
    /// sessions on the broker) while not being guessable from the device name.
    static func clientIDSuffix(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: clientIDSuffixKey), !existing.isEmpty {
            return existing
        }
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .lowercased().prefix(8))
        defaults.set(suffix, forKey: clientIDSuffixKey)
        return suffix
    }

    /// `allarise-<device>-<8 hex>`. Nothing keys on the client ID — topics are
    /// built from the sanitized device name, and neither the HACS integration nor
    /// the docs reference it — so the suffix is safe to add. Capped well under the
    /// 128-character limit brokers commonly enforce.
    static func mqttClientID(deviceName: String, defaults: UserDefaults = .standard) -> String {
        let suffix = clientIDSuffix(defaults: defaults)
        let maxNameLength = 100 - "allarise-".count - 1 - suffix.count
        let name = String(deviceName.prefix(max(maxNameLength, 0)))
        return "allarise-\(name)-\(suffix)"
    }

    // MARK: - Connection Management

    func connect(settings: DeviceSettings) {
        guard settings.mqttEnabled else {
            mqttLog("⚠️ MQTT disabled in settings")
            disconnect()
            return
        }
        
        isIntentionalDisconnect = false
        
        // Get broker config based on current network
        let config = NetworkMonitor.shared.getBrokerConfig(settings: settings)
        let netReady = NetworkMonitor.shared.hasResolvedInitialNetwork
        
        guard !config.host.isEmpty else {
            mqttLog("❌ Host not configured (network resolved: \(netReady), home: \(NetworkMonitor.shared.isOnHomeNetwork), SSID: \(NetworkMonitor.shared.currentSSID ?? "nil"))")
            connectionState = .notConfigured
            return
        }

        guard !settings.mqttUsername.isEmpty, !settings.mqttPassword.isEmpty else {
            mqttLog("MQTT credentials not set — username and password are required. Configure them in MQTT Settings.")
            connectionState = .notConfigured
            return
        }
        
        // Check if we need to reconnect (host changed)
        let newHost = "\(config.host):\(config.port)"
        if client != nil, lastUsedHost == newHost, isConnected {
            mqttLog("✅ Already connected to \(newHost)")
            return
        }
        
        // Disconnect existing connection
        if client != nil {
            mqttLog("🔄 Switching broker to \(newHost)")
            disconnect()
        }
        
        lastUsedHost = newHost
        connectionState = .connecting
        
        // Create MQTT client
        let clientID = Self.mqttClientID(deviceName: settings.sanitizedDeviceName)
        let mqtt = CocoaMQTT(clientID: clientID, host: config.host, port: UInt16(config.port))
        
        // Configure client
        mqtt.username = settings.mqttUsername.isEmpty ? nil : settings.mqttUsername
        mqtt.password = settings.mqttPassword.isEmpty ? nil : settings.mqttPassword
        mqtt.keepAlive = 30  // Shorter keep-alive for faster stale connection detection
        mqtt.delegate = self
        // Delegate callbacks on MAIN, deliberately. `pendingPublishCallbacks` is
        // a plain dictionary written from `publish` and from the 5s timeout (both
        // main) and read from `didPublishAck`; on CocoaMQTT's own queue that ack
        // raced the timeout and could corrupt the dictionary's storage. Every
        // callback here is either a log, a `Task { @MainActor }` hop, or a small
        // parse — the one piece of work that could block (TLS trust evaluation,
        // which may hit the network for revocation) is explicitly moved off main
        // in `mqtt(_:didReceive:completionHandler:)`.
        mqtt.delegateQueue = .main
        mqtt.autoReconnect = true
        mqtt.autoReconnectTimeInterval = 5  // Reconnect quickly after disconnect
        mqtt.enableSSL = config.useTLS
        
        // Clean session: subscriptions and state are re-established on every connect
        // (didConnectAck), and a persistent session would replay commands queued
        // while the app was offline.
        mqtt.cleanSession = true
        
        if config.useTLS {
            mqtt.allowUntrustCACertificate = false
        }
        
        // Set will message (offline status when disconnected ungracefully)
        let availabilityTopic = "\(settings.mqttTopicPrefix)/\(settings.sanitizedDeviceName)/availability"
        mqtt.willMessage = CocoaMQTTMessage(topic: availabilityTopic, string: "offline", qos: .qos1, retained: true)
        
        self.client = mqtt

        // Ensure background audio is running so MQTT stays connected in background.
        // Skipped when App Persistence is off, and also when an alarm is currently
        // ringing — starting keep-alive during an alarm races the alarm's own
        // .playAndRecord session setup and can leave the alarm tone silent.
        // AlarmSound.stop() restarts keep-alive once the alarm is dismissed.
        if DeviceSettings.shared.keepAliveNeeded,
           PendingAlarmStore.shared.activeRingingAlarmID() == nil {
            Task {
                await BackgroundAudioKeepAlive.shared.startAsync()
            }
        }
        
        let userDesc = mqtt.username.map { $0.isEmpty ? "none" : "\($0.prefix(3))***" } ?? "none"
        mqttLog("🔌 Connecting to \(config.host):\(config.port) (TLS: \(config.useTLS), clean: \(mqtt.cleanSession), user: \(userDesc), clientID: \(clientID))")
        
        // DNS resolution diagnostic — log what IP the hostname resolves to
        let dnsHost = config.host
        Task.detached {
            let cfHost = CFHostCreateWithName(nil, dnsHost as CFString).takeRetainedValue()
            var resolved = DarwinBoolean(false)
            CFHostStartInfoResolution(cfHost, .addresses, nil)
            if let addresses = CFHostGetAddressing(cfHost, &resolved)?.takeUnretainedValue() as? [Data], resolved.boolValue {
                let ips = addresses.compactMap { data -> String? in
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let result = data.withUnsafeBytes { ptr -> Int32 in
                        guard let addr = ptr.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return -1 }
                        return getnameinfo(addr, socklen_t(data.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    }
                    return result == 0 ? String(cString: hostname) : nil
                }
                let message = "🔍 DNS resolved '\(dnsHost)' → \(ips.joined(separator: ", "))"
                await MainActor.run { MQTTManager.shared.mqttLog(message) }
            } else {
                let message = "⚠️ DNS resolution failed for '\(dnsHost)' — check hostname/network"
                await MainActor.run { MQTTManager.shared.mqttLog(message) }
            }
        }
        
        let success = mqtt.connect()
        
        if !success {
            mqttLog("❌ Failed to initiate MQTT connection")
            connectionState = .error("Connection failed")
        } else {
            // Start a connection timeout — if still connecting after 15s, the TLS handshake likely hung
            connectionTimeoutTimer?.invalidate()
            connectionTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    if case .connecting = self.connectionState {
                        self.mqttLog("⏱️ Connection timeout after 15s — TLS handshake may have failed. Check that your certificate matches the hostname '\(config.host)' and the broker accepts your credentials.")
                        self.connectionState = .error("Connection timeout (TLS?)")
                        self.client?.disconnect()
                        self.scheduleReconnect()
                    }
                }
            }
        }
    }
    
    /// Force a full disconnect + reconnect cycle.
    /// Use this for the manual reconnect button and network changes
    /// where the connection may be stale or the broker may have changed.
    func forceReconnect(settings: DeviceSettings) {
        mqttLog("🔄 Force reconnect requested")

        // Tear down existing connection completely
        reconnectBackoffIndex = 0
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        connectivityCheckTimer?.invalidate()
        connectivityCheckTimer = nil
        
        // Disable auto-reconnect on the old client so it doesn't fight us
        client?.autoReconnect = false
        client?.disconnect()
        client = nil
        lastUsedHost = nil
        connectionState = .disconnected
        isIntentionalDisconnect = false
        
        // Small delay to let the old socket fully close before reconnecting
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.connect(settings: settings)
        }
    }
    
    func disconnect() {
        isIntentionalDisconnect = true
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        connectivityCheckTimer?.invalidate()
        connectivityCheckTimer = nil

        if let mqtt = client {
            // Publish retained "offline" before graceful disconnect
            // (will message only fires on ungraceful disconnects)
            let settings = DeviceSettings.shared
            let availabilityTopic = "\(settings.mqttTopicPrefix)/\(settings.sanitizedDeviceName)/availability"
            mqtt.publish(availabilityTopic, withString: "offline", qos: .qos1, retained: true)
            mqtt.disconnect()
        }
        
        client = nil
        lastUsedHost = nil
        connectionState = .disconnected
        stopSystemVolumeMonitoring()
        mqttLog("🔌 MQTT disconnected")
    }
    
    private func handleNetworkChange() {
        guard !isIntentionalDisconnect else { return }

        reconnectBackoffIndex = 0

        let settings = DeviceSettings.shared
        guard settings.mqttEnabled else { return }
        
        // Check if the broker would change based on the new network
        let config = NetworkMonitor.shared.getBrokerConfig(settings: settings)
        let newHost = "\(config.host):\(config.port)"
        
        if lastUsedHost != newHost {
            // Broker changed (e.g., switched from external to internal) — force reconnect
            mqttLog("🌐 Network changed, broker switching: \(lastUsedHost ?? "none") → \(newHost)")
            forceReconnect(settings: settings)
        } else if !isConnected {
            // Same broker but disconnected — just reconnect
            mqttLog("🌐 Network changed, reconnecting to same broker...")
            connect(settings: settings)
        } else {
            mqttLog("🌐 Network changed, already connected to \(newHost)")
        }
    }
    
    private func handleAppWillEnterForeground() {
        guard !isIntentionalDisconnect else { return }
        
        let settings = DeviceSettings.shared
        guard settings.mqttEnabled else { return }
        
        mqttLog("📱 App entering foreground — checking MQTT connection...")

        // Restart background audio in case it was interrupted — only when App
        // Persistence is on AND no alarm is currently ringing. Running keep-alive
        // while an alarm is firing would race the alarm's own .playAndRecord
        // category setup; AlarmSound.stop() will restart keep-alive when the
        // alarm ends, so deferring here is safe.
        if DeviceSettings.shared.keepAliveNeeded,
           PendingAlarmStore.shared.activeRingingAlarmID() == nil {
            Task {
                await BackgroundAudioKeepAlive.shared.startAsync()
            }
        }
        
        // If not connected, reconnect immediately
        if !isConnected {
            mqttLog("🔄 MQTT disconnected while in background — reconnecting...")
            connect(settings: settings)
        }
    }
    
    private func handleAppDidBecomeActive() {
        guard !isIntentionalDisconnect else { return }
        
        let settings = DeviceSettings.shared
        guard settings.mqttEnabled else { return }
        
        // Double-check connection after becoming active (slight delay for network to stabilize)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, !self.isIntentionalDisconnect else { return }
            
            if !self.isConnected {
                self.mqttLog("🔄 MQTT still disconnected after becoming active — reconnecting...")
                self.connect(settings: settings)
            } else {
                // Verify the connection is actually alive by checking last pong time
                let timeSinceLastPong = Date().timeIntervalSince(self.lastPongTime)
                if timeSinceLastPong > 120 {
                    self.mqttLog("⚠️ No MQTT pong in \(Int(timeSinceLastPong))s — stale, force reconnecting...")
                    self.forceReconnect(settings: settings)
                }
            }
        }
        
        // Start periodic connectivity check while app is active
        startConnectivityCheck()
    }
    
    private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        switch type {
        case .began:
            print("⚠️ Audio session interrupted — background keep-alive may stop")
        case .ended:
            print("✅ Audio session interruption ended — restarting background audio")
            if DeviceSettings.shared.keepAliveNeeded,
               PendingAlarmStore.shared.activeRingingAlarmID() == nil {
                Task {
                    await BackgroundAudioKeepAlive.shared.startAsync()
                }
            }
            // Also check MQTT after audio resumes
            if !isIntentionalDisconnect && DeviceSettings.shared.mqttEnabled && !isConnected {
                connect(settings: DeviceSettings.shared)
            }
        @unknown default:
            break
        }
    }
    
    /// Periodically checks MQTT connectivity while the app is active
    private func startConnectivityCheck() {
        connectivityCheckTimer?.invalidate()
        connectivityCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self, !self.isIntentionalDisconnect else { return }
            
            let settings = DeviceSettings.shared
            guard settings.mqttEnabled else { return }
            
            if !self.isConnected {
                // Watchdog only — while a backoff reconnect is already armed,
                // don't force attempts faster than the backoff interval.
                if let timer = self.reconnectTimer, timer.isValid { return }
                self.mqttLog("🔄 Connectivity check: MQTT disconnected — reconnecting...")
                self.connect(settings: settings)
            }
        }
    }
    
    private func scheduleReconnect() {
        guard !isIntentionalDisconnect else { return }

        let interval = reconnectBackoffIntervals[reconnectBackoffIndex]
        reconnectBackoffIndex = min(reconnectBackoffIndex + 1, reconnectBackoffIntervals.count - 1)

        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.mqttLog("🔄 Attempting MQTT reconnect (after \(Int(interval))s backoff)...")
            self.connect(settings: DeviceSettings.shared)
        }
    }
    
    // MARK: - State Publishing Helpers
    
    /// Publish "online" availability and initial state after connecting.
    /// Discovery is handled by the HACS integration; the app only publishes state.
    func publishOnlineState(settings: DeviceSettings) {
        guard isConnected else { return }
        let prefix = settings.mqttTopicPrefix
        let deviceName = settings.sanitizedDeviceName
        let availabilityTopic = "\(prefix)/\(deviceName)/availability"
        publish(topic: availabilityTopic, payload: "online", retain: true)
        
        // Publish commands count sensor state
        publish(
            topic: "\(prefix)/\(deviceName)/sensor/commands_count",
            payload: "\(settings.mqttCommands.count)",
            retain: settings.mqttPublishRetained
        )
        
        // Initialize per-command status sensors to "idle".
        // Uses the same slug helper the fired/idle publish does — these were two
        // copies of the same transform, so a command whose name slugged to
        // nothing seeded one topic and fired on another.
        for command in settings.mqttCommands {
            let sanitizedName = sanitizeCommandName(command.name)
            publish(
                topic: "\(prefix)/\(deviceName)/command/\(sanitizedName)/status",
                payload: "idle",
                retain: settings.mqttPublishRetained
            )
        }
        
        // Publish current system volume so the HA slider initializes correctly
        let currentSystemVolume = Double(VolumeManager.shared.getCurrentVolume())
        publishSystemVolume(currentSystemVolume, settings: settings)

        // Publish available sleep sounds so the HA dropdown reflects bundled + custom
        publishAvailableSleepSounds(settings: settings)
        // Same for alarm tones, so the create/update alarm + trigger_alert sound
        // dropdowns offer what this device can actually play.
        publishAvailableAlarmSounds(settings: settings)
        // Station list + current transport state, so a dashboard built before
        // the app started playing still has something to render.
        publishRadioFavorites(settings: settings)
        publishRadioState(settings: settings)

        // App Persistence. Seeded HERE rather than alongside the alert settings
        // in didConnectAck because publishOnlineState is also what runs when
        // Home Assistant restarts and sends its birth message — a restarted HA
        // with no retained value would otherwise show the switch as unavailable
        // until the setting next changed, which for this setting is rarely.
        // EFFECTIVE residency, not the raw mode — under Dynamic the switch
        // stays truthful about whether the app is actually reachable.
        publishAppPersistence(settings.keepAliveNeeded, settings: settings)
        // ...and the raw mode alongside it, seeded here for the same reason:
        // it is the only thing that says WHICH of the three modes is set, and
        // a restarted HA must not have to wait for the next change to learn it.
        publishAppPersistenceMode(settings.appPersistenceMode, settings: settings)

        // Kids Sleep (al-2se): re-sync every kid's retained schedule (the
        // device-independent kids_sleep tree) so sessions created while the
        // broker was unreachable still reach HA and peer phones. Only existing
        // sessions and, if non-empty, the roster — publishing empties here would
        // plant stray retained topics on the broker of every user who never
        // touched the (debug-only) feature. A newer retained roster/session
        // arriving afterwards wins via reconcile.
        SleepTimerStore.shared.republishAllToHA()
        SleepTimerStore.shared.republishRosterIfNonEmpty()

        print("✅ Published online state (discovery handled by HACS)")
    }
    
    /// Publish confirmed arm state to the state topic (retained).
    /// Called when:
    ///   - User toggles in the app (completeHold)
    ///   - HA sends a command on the command topic (we echo it back as confirmed state)
    /// Request an arm state change from HA. HA is the source of truth.
    /// Publishes a non-retained request to the zone's set topic; HA confirms by
    /// publishing retained to the zone's state topic, which we receive and display.
    /// The zone topic is shared across all devices using the same zone name, so
    /// multiple phones (e.g. husband and wife) see the same arm state.
    func requestArmStateChange(_ armed: Bool, settings: DeviceSettings) {
        let topic = "\(settings.mqttTopicPrefix)/alarm/\(settings.armZoneSlug)/set"
        publish(topic: topic, payload: armed ? "ON" : "OFF", retain: false)
        mqttLog("📡 Arm zone '\(settings.armZone)' → HA: \(armed ? "ON" : "OFF")")
    }
    
    /// Sanitize a command name for use in MQTT topic segments.
    /// Lowercases, replaces spaces with underscores, strips non-alphanumeric chars.
    ///
    /// See `MQTTStrings.commandTopicSlug` for why the transform is frozen for
    /// every name that already works, and what happens to the ones that used to
    /// slug to nothing.
    func sanitizeCommandName(_ name: String) -> String {
        MQTTStrings.commandTopicSlug(name)
    }

    /// Publish custom command text as a sensor value
    func publishArmCustomCommand(_ command: String, settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/arm_custom_command"
        publish(topic: topic, payload: command, retain: settings.mqttPublishRetained)
        mqttLog("📡 Published arm custom command: \(command)")

        // Per-command status: publish "fired" then reset to "idle" after 2 seconds
        let sanitizedName = sanitizeCommandName(command)
        let statusTopic = "\(settings.mqttTopicPrefix)/\(deviceName)/command/\(sanitizedName)/status"
        publish(topic: statusTopic, payload: "fired", retain: settings.mqttPublishRetained)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.publish(topic: statusTopic, payload: "idle", retain: settings.mqttPublishRetained)
        }
    }
    
    // MARK: - State Publishing
    
    func publishAlarmState(_ state: AlarmState, settings: DeviceSettings) {
        guard isConnected else { return }
        
        currentAlarmState = state
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/alarm_state"
        publish(topic: topic, payload: state.rawValue, retain: settings.mqttPublishRetained)
        
        // Update Dashboard button availability based on alarm state
        publishDashboardButtonAvailability(state: state, settings: settings)
        
        print("📡 Published alarm state: \(state.rawValue)")
    }
    
    /// Publishes availability for Dashboard action buttons based on alarm state.
    /// - Dismiss/Snooze/Skip: available when ringing or snoozed
    /// - Kill Snoozed: available only when snoozed
    func publishDashboardButtonAvailability(state: AlarmState, settings: DeviceSettings) {
        guard isConnected else { return }
        let prefix = settings.mqttTopicPrefix
        let deviceName = settings.sanitizedDeviceName
        let retain = settings.mqttPublishRetained
        
        let isActive = (state == .ringing || state == .snoozed)
        
        publish(topic: "\(prefix)/\(deviceName)/dashboard/dismiss_availability", payload: isActive ? "online" : "offline", retain: retain)
        publish(topic: "\(prefix)/\(deviceName)/dashboard/snooze_availability", payload: isActive ? "online" : "offline", retain: retain)
        publish(topic: "\(prefix)/\(deviceName)/dashboard/kill_snoozed_availability", payload: (state == .snoozed) ? "online" : "offline", retain: retain)
    }
    
    func publishSnoozeCount(_ count: Int, settings: DeviceSettings) {
        guard isConnected else { return }
        
        snoozeCount = count
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/snooze_count"
        publish(topic: topic, payload: "\(count)", retain: settings.mqttPublishRetained)
        print("📡 Published snooze count: \(count)")
    }
    
    func publishSnoozesRemaining(_ remaining: Int, settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/snoozes_remaining"
        publish(topic: topic, payload: "\(remaining)", retain: settings.mqttPublishRetained)
        print("📡 Published snoozes remaining: \(remaining)")
    }
    
    func publishActiveAlarmIndex(_ index: Int?, settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/active_alarm_index"
        publish(topic: topic, payload: index.map { "\($0)" } ?? "none", retain: settings.mqttPublishRetained)
        print("📡 Published active alarm index: \(index.map { "\($0)" } ?? "none")")
    }
    
    func publishActiveAlarmName(_ name: String?, settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/active_alarm_name"
        publish(topic: topic, payload: name ?? "none", retain: settings.mqttPublishRetained)
        print("📡 Published active alarm name: \(name ?? "none")")
    }
    
    func publishActiveAlarmMission(_ mission: String, settings: DeviceSettings) {
        guard isConnected else { return }
        
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/active_alarm_mission"
        publish(topic: topic, payload: mission, retain: settings.mqttPublishRetained)
        print("📡 Published active alarm mission: \(mission)")
    }
    
    func publishActiveAlarmDays(_ days: String, settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/active_alarm_days"
        publish(topic: topic, payload: days, retain: settings.mqttPublishRetained)
        print("📡 Published active alarm days: \(days)")
    }
    
    func publishActiveAlarmFireTime(_ date: Date?, settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let base = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/active_alarm_fire_time"
        if let date {
            let display = DateFormatter(); display.dateStyle = .short; display.timeStyle = .short
            publish(topic: base, payload: ISO8601DateFormatter().string(from: date), retain: settings.mqttPublishRetained)
            publish(topic: "\(base)_display", payload: display.string(from: date), retain: settings.mqttPublishRetained)
        } else {
            publish(topic: base, payload: "none", retain: settings.mqttPublishRetained)
            publish(topic: "\(base)_display", payload: "none", retain: settings.mqttPublishRetained)
        }
    }
    
    func publishActiveAlarmSnoozeFireTime(_ date: Date?, settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let base = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/active_alarm_snooze_fire_time"
        if let date {
            let display = DateFormatter(); display.dateStyle = .short; display.timeStyle = .short
            publish(topic: base, payload: ISO8601DateFormatter().string(from: date), retain: settings.mqttPublishRetained)
            publish(topic: "\(base)_display", payload: display.string(from: date), retain: settings.mqttPublishRetained)
        } else {
            publish(topic: base, payload: "none", retain: settings.mqttPublishRetained)
            publish(topic: "\(base)_display", payload: "none", retain: settings.mqttPublishRetained)
        }
    }
    
    // MARK: - Queue-Based Alarm Detail Sensors

    func publishActiveAlarmSound(_ sound: String?, settings: DeviceSettings) {
        guard isConnected else { return }
        let topic = "\(settings.mqttTopicPrefix)/\(settings.sanitizedDeviceName)/sensor/alarm_sound"
        publish(topic: topic, payload: sound ?? "none", retain: settings.mqttPublishRetained)
    }

    func publishActiveAlarmVolume(_ volume: Double?, settings: DeviceSettings) {
        guard isConnected else { return }
        let topic = "\(settings.mqttTopicPrefix)/\(settings.sanitizedDeviceName)/sensor/alarm_volume"
        if let volume {
            publish(topic: topic, payload: "\(Int(volume * 100))%", retain: settings.mqttPublishRetained)
        } else {
            publish(topic: topic, payload: "none", retain: settings.mqttPublishRetained)
        }
    }

    func publishActiveAlarmVibrate(_ enabled: Bool?, settings: DeviceSettings) {
        guard isConnected else { return }
        let topic = "\(settings.mqttTopicPrefix)/\(settings.sanitizedDeviceName)/sensor/alarm_vibrate"
        publish(topic: topic, payload: enabled.map { $0 ? "on" : "off" } ?? "none", retain: settings.mqttPublishRetained)
    }

    func publishActiveAlarmFadeIn(_ enabled: Bool?, settings: DeviceSettings) {
        guard isConnected else { return }
        let topic = "\(settings.mqttTopicPrefix)/\(settings.sanitizedDeviceName)/sensor/alarm_fade_in"
        publish(topic: topic, payload: enabled.map { $0 ? "on" : "off" } ?? "none", retain: settings.mqttPublishRetained)
    }



    func publishNextAlarmName(_ name: String?, settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/next_alarm_name"
        publish(topic: topic, payload: name ?? "none", retain: settings.mqttPublishRetained)
        print("📡 Published next alarm name: \(name ?? "none")")
    }
    
    func publishNextAlarmFireTime(_ date: Date?, settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let base = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/next_alarm_fire_time"
        if let date {
            let display = DateFormatter(); display.dateStyle = .short; display.timeStyle = .short
            publish(topic: base, payload: ISO8601DateFormatter().string(from: date), retain: settings.mqttPublishRetained)
            publish(topic: "\(base)_display", payload: display.string(from: date), retain: settings.mqttPublishRetained)
        } else {
            publish(topic: base, payload: "none", retain: settings.mqttPublishRetained)
            publish(topic: "\(base)_display", payload: "none", retain: settings.mqttPublishRetained)
        }
    }
    
    func publishTotalAlarmCount(_ count: Int, settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/total_alarm_count"
        publish(topic: topic, payload: "\(count)", retain: settings.mqttPublishRetained)
        print("📡 Published total alarm count: \(count)")
    }
    
    func publishEnabledAlarmCount(_ count: Int, settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/enabled_alarm_count"
        publish(topic: topic, payload: "\(count)", retain: settings.mqttPublishRetained)
        print("📡 Published enabled alarm count: \(count)")
    }
    
    func publishSleepSoundVolume(_ volume: Double, settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/sleep_sound_volume"
        publish(topic: topic, payload: "\(Int(volume * 100))", retain: false)
        print("📡 Published sleep sound volume: \(Int(volume * 100))%")
    }

    func publishSystemVolume(_ volume: Double, settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/system_volume"
        publish(topic: topic, payload: "\(Int(volume * 100))", retain: false)
        print("📡 Published system volume: \(Int(volume * 100))%")
    }

    // MARK: - System Volume Monitoring

    /// Start observing hardware volume button changes and publishing them to HA.
    /// Uses a 0.5s debounce so rapid button presses send only one update.
    func startSystemVolumeMonitoring() {
        guard systemVolumeObserver == nil else { return }
        systemVolumeObserver = AVAudioSession.sharedInstance().observe(
            \.outputVolume,
            options: [.new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async { self?.handleSystemVolumeChanged() }
        }
        print("🔊 System volume monitoring started")
    }

    func stopSystemVolumeMonitoring() {
        systemVolumeObserver?.invalidate()
        systemVolumeObserver = nil
        systemVolumeDebounce?.cancel()
        systemVolumeDebounce = nil
        print("🔊 System volume monitoring stopped")
    }

    private func handleSystemVolumeChanged() {
        systemVolumeDebounce?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.isConnected else { return }
            let settings = DeviceSettings.shared
            let volume = Double(VolumeManager.shared.getCurrentVolume())
            self.publishSystemVolume(volume, settings: settings)
        }
        systemVolumeDebounce = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }

    func publishSleepSoundName(_ name: String, settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/sleep_sound"

        // Custom sounds are tracked internally by `custom_<uuid>` id, but HA's
        // Sleep Sound select lists them by MQTT-safe display name. Translate so
        // current_option matches — bundled and "none" pass through unchanged.
        let publishName: String
        if name.hasPrefix("custom_"),
           let custom = CustomSoundManager.shared.sound(byID: name) {
            publishName = custom.mqttName
        } else {
            publishName = name
        }

        publish(topic: topic, payload: publishName, retain: true)
        print("📡 Published sleep sound name: \(publishName)")
    }

    /// Publish the user's favourited radio stations as a retained JSON array so
    /// Home Assistant can build a station dropdown instead of hardcoding names.
    ///
    /// Deliberately mirrors `publishAvailableSleepSounds`: same shape, same
    /// retained-JSON contract. Names only — `radio_start` and `create_alarm`
    /// both accept a favourite by name, so a name is a usable handle, and the
    /// stream URLs are not something a dashboard should be echoing.
    ///
    /// Names are cleaned before they go out (`MQTTStrings.publishedName`) and
    /// de-duplicated. Station names come from an open directory, not from us:
    /// trailing spaces, embedded newlines, zero-width joiners and 300-character
    /// titles are all routine there, and each one breaks something on the other
    /// side — a control character renders as mojibake in the dropdown, a
    /// duplicate name gives two rows only one of which can ever resolve, and
    /// anything over 255 characters takes the whole sensor to "unknown".
    /// The favourite itself keeps its original name; only the published form is
    /// cleaned, and `resolveRadioStation` matches either shape, so an automation
    /// written against the raw name keeps working.
    func publishRadioFavorites(settings: DeviceSettings) {
        guard isConnected else { return }
        let topic = "\(settings.mqttTopicPrefix)/\(settings.sanitizedDeviceName)/sensor/radio_stations_available"
        let names = MQTTStrings.uniqueNonEmpty(
            RadioPlayerManager.shared.favorites.map { MQTTStrings.publishedName($0.name) }
        ).sorted()
        guard let data = try? JSONSerialization.data(withJSONObject: names, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        publish(topic: topic, payload: json, retain: true)
    }

    /// Publish the live radio transport state. Cleared to `stopped` / `none`
    /// rather than an empty payload so HA entities show a real value.
    func publishRadioState(settings: DeviceSettings) {
        guard isConnected else { return }
        let base = "\(settings.mqttTopicPrefix)/\(settings.sanitizedDeviceName)/sensor"
        let manager = RadioPlayerManager.shared
        let state: String
        switch manager.state {
        case .stopped:  state = "stopped"
        case .paused:   state = "paused"
        default:        state = "playing"
        }
        publish(topic: "\(base)/radio_state", payload: state, retain: true)
        // Cleaned the same way the favourites list is, so the Radio Station
        // select can match `current_option` against its own options. Publishing
        // the raw name here and a cleaned one there would leave the dropdown
        // permanently showing "none" while a station was plainly playing.
        let stationName = manager.currentStation.map { MQTTStrings.publishedName($0.name) } ?? "none"
        publish(topic: "\(base)/radio_station",
                payload: stationName.isEmpty ? "none" : stationName,
                retain: true)
    }

    /// Publish the full list of sleep sound MQTT names (bundled + custom) as a retained
    /// JSON array so the HACS Sleep Sound dropdown stays in sync with the app.
    func publishAvailableSleepSounds(settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/sleep_sounds_available"

        let bundledAndImported = SleepSoundManager.availableSounds()
            .filter { !$0.hasPrefix("custom_") }
        let customMqttNames = CustomSoundManager.shared.sleepSounds().map(\.mqttName)
        let all = Array(Set(bundledAndImported + customMqttNames)).sorted()

        guard let data = try? JSONSerialization.data(withJSONObject: all, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        publish(topic: topic, payload: json, retain: true)
        print("📡 Published available sleep sounds (\(all.count))")
    }

    /// Publish the full list of alarm tone names (bundled + custom) as a retained
    /// JSON array, so the HACS sound dropdowns (`create_alarm`, `update_alarm`,
    /// `trigger_alert`) offer what the app can actually play instead of a
    /// free-text box the user has to guess at.
    ///
    /// Deliberately mirrors `publishAvailableSleepSounds`: same retained-JSON
    /// contract, same cleaning (`MQTTStrings.publishedName`) and de-duplication
    /// (`MQTTStrings.uniqueNonEmpty`), retained unconditionally so a dashboard
    /// built before the app next launches still has a list.
    ///
    /// What differs is WHICH handle goes on the wire. It has to be one that
    /// `AlarmSoundManager.getSound(id:)` resolves, or the dropdown builds
    /// payloads the app silently ignores:
    ///   • bundled tones publish their `AlarmSound.id` — the filename stem
    ///     (`Alarm_Clock`), which is what `sound:` has always accepted;
    ///   • custom tones publish their `mqttName` (display name, spaces →
    ///     underscores), NOT the `custom_<UUID>` id. `getSound(id:)` already
    ///     falls back to that name, and a UUID in a dropdown tells the user
    ///     nothing about which tone it is.
    ///
    /// Bundled ids come first so that when a custom tone is named after a bundled
    /// one ("Alarm Clock" → `Alarm_Clock`), the entry that survives
    /// de-duplication is the one `getSound(id:)` matches first.
    ///
    /// The custom half reads `CustomSoundManager` directly rather than the custom
    /// entries of `getAllSounds()`, so this is immune to the alarm-sound cache
    /// being stale: `saveMetadata()` calls us before `invalidateCache()` runs.
    func publishAvailableAlarmSounds(settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/alarm_sounds_available"

        let bundled = AlarmSoundManager.shared.getAllSounds()
            .filter { !$0.id.hasPrefix("custom_") }
            .map { MQTTStrings.publishedName($0.id) }
        let custom = CustomSoundManager.shared.alarmTones()
            .map { MQTTStrings.publishedName($0.mqttName) }
        // Dedupe with bundled first (uniqueNonEmpty keeps the first occurrence),
        // then sort for the dropdown.
        let all = MQTTStrings.uniqueNonEmpty(bundled + custom).sorted()

        guard let data = try? JSONSerialization.data(withJSONObject: all, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        publish(topic: topic, payload: json, retain: true)
        print("📡 Published available alarm sounds (\(all.count))")
    }

    func publishDisabledAlarmCount(_ count: Int, settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/disabled_alarm_count"
        publish(topic: topic, payload: "\(count)", retain: settings.mqttPublishRetained)
        print("📡 Published disabled alarm count: \(count)")
    }
    
    func publishBrokerConnectionType(_ type: String, settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/broker_connection"
        publish(topic: topic, payload: type, retain: settings.mqttPublishRetained)
        print("📡 Published broker connection type: \(type)")
    }
    
    func publishAppVersion(settings: DeviceSettings) {
        guard isConnected else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/app_version"
        publish(topic: topic, payload: "\(version) (\(build))", retain: settings.mqttPublishRetained)
        print("📡 Published app version: \(version) (\(build))")
    }
    
    // MARK: - Media Alert Volume
    
    func publishMediaAlertVolume(_ volume: Double, settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/media_alert_volume"
        let pct = Int(volume * 100)
        publish(topic: topic, payload: "\(pct)", retain: settings.mqttPublishRetained)
        print("📡 Published media alert volume: \(pct)%")
    }
    
    // MARK: - Alert Configuration Sensors
    
    func publishAlertVibrationEnabled(_ enabled: Bool, settings: DeviceSettings) {
        guard isConnected else { return }
        let topic = "\(settings.mqttTopicPrefix)/\(settings.sanitizedDeviceName)/sensor/alert_vibrate"
        publish(topic: topic, payload: enabled ? "on" : "off", retain: settings.mqttPublishRetained)
    }
    
    func publishAlertLoopMedia(_ enabled: Bool, settings: DeviceSettings) {
        guard isConnected else { return }
        let topic = "\(settings.mqttTopicPrefix)/\(settings.sanitizedDeviceName)/sensor/alert_loop_media"
        publish(topic: topic, payload: enabled ? "on" : "off", retain: settings.mqttPublishRetained)
    }
    
    func publishAlertLoopDelay(_ seconds: Double, settings: DeviceSettings) {
        guard isConnected else { return }
        let topic = "\(settings.mqttTopicPrefix)/\(settings.sanitizedDeviceName)/sensor/alert_loop_delay"
        publish(topic: topic, payload: "\(Int(seconds))", retain: settings.mqttPublishRetained)
    }
    
    func publishAlertDefaultSound(_ soundID: String, settings: DeviceSettings) {
        guard isConnected else { return }
        let topic = "\(settings.mqttTopicPrefix)/\(settings.sanitizedDeviceName)/sensor/alert_sound"
        let payload = soundID.isEmpty
            ? (AlarmSoundManager.shared.getDefaultSound().displayName + " (default)")
            : (AlarmSoundManager.shared.getSound(id: soundID)?.displayName ?? soundID)
        publish(topic: topic, payload: payload, retain: settings.mqttPublishRetained)
    }

    // MARK: - App Persistence

    /// Publish the App Persistence setting (background audio keep-alive).
    ///
    /// This is the answer to "did my command work?". The command topic is
    /// fire-and-forget with no reply, so Home Assistant sends
    /// `command/app_persistence` and then watches THIS topic: it changes, or the
    /// phone never heard it. `DeviceSettings.backgroundKeepAliveEnabled`'s
    /// `didSet` calls this on every assignment — including one that sets the
    /// value it already had — so a no-op command still produces a message.
    ///
    /// Retained unconditionally rather than honouring `mqttPublishRetained`,
    /// which is deliberate and worth the inconsistency. This value changes maybe
    /// twice a year; without retention Home Assistant would sit on `unknown`
    /// from every restart until the next time someone touched the setting, and
    /// the switch entity would be unusable in exactly the situation it exists
    /// for. Staleness is not hidden by this: the retained `availability` topic
    /// (and its LWT) is what says whether the value is still live, and the HACS
    /// switch marks itself `unavailable` when it is not.
    ///
    /// Note the honest limitation this cannot paper over — with persistence OFF
    /// the app is suspended, so nothing is connected to receive the command that
    /// would turn it back on. That is not a bug to be worked around; it is why
    /// availability is part of the contract.
    func publishAppPersistence(_ enabled: Bool, settings: DeviceSettings) {
        guard isConnected else { return }
        let topic = "\(settings.mqttTopicPrefix)/\(settings.sanitizedDeviceName)/sensor/app_persistence"
        publish(topic: topic, payload: enabled ? "on" : "off", retain: true)
        print("📡 Published app persistence: \(enabled ? "on" : "off")")
    }

    /// Publish the RAW App Persistence mode ("on" / "off" / "dynamic").
    ///
    /// A companion to `publishAppPersistence`, not a replacement for it: that
    /// topic keeps meaning EFFECTIVE residency (is the app resident right now)
    /// because a switch entity and every automation built on it already read it
    /// that way. This one answers the different question "which of the three
    /// modes did the user choose", which under `.dynamic` the effective topic
    /// cannot express — it flips on and off all night by design.
    ///
    /// Retained for the same reason and on the same terms as the effective
    /// topic: it changes rarely, and without retention a restarted Home
    /// Assistant would show `unknown` until the setting next moved.
    func publishAppPersistenceMode(_ mode: AppPersistenceMode, settings: DeviceSettings) {
        guard isConnected else { return }
        let topic = "\(settings.mqttTopicPrefix)/\(settings.sanitizedDeviceName)/sensor/app_persistence_mode"
        publish(topic: topic, payload: mode.rawValue, retain: true)
        print("📡 Published app persistence mode: \(mode.rawValue)")
    }

    // MARK: - Sleep/Wake State Sensors

    func publishUserState(_ state: String, settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/user_state"
        publish(topic: topic, payload: state, retain: settings.mqttPublishRetained)
        print("📡 Published user state: \(state)")
    }
    
    func publishWakeAlarmName(_ name: String, settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/wake_alarm_name"
        publish(topic: topic, payload: name, retain: settings.mqttPublishRetained)
        print("📡 Published wake alarm name: \(name)")
    }
    
    func publishDayStartedAt(_ timestamp: String, settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let topic = "\(settings.mqttTopicPrefix)/\(deviceName)/sensor/day_started_at"
        publish(topic: topic, payload: timestamp, retain: settings.mqttPublishRetained)
        print("📡 Published day started at: \(timestamp)")
    }

    // MARK: - Slept-Through Sensor (al-bee.5)

    /// Publish how many alarms the user slept through today, plus a small
    /// detail list.
    ///
    /// ADDITIVE, in both skew directions:
    ///  * Two brand-new topics. No existing topic, payload key, state value or
    ///    HA service is touched, so every automation keeps working verbatim.
    ///  * An older app publishes neither, so the HACS sensor stays
    ///    absent/unknown — never an error.
    ///  * An older HACS integration simply never subscribes, and an unread
    ///    retained topic costs the broker one small message.
    ///
    /// Retained (like `radio_stations_available` and `app_persistence_mode`):
    /// the value changes at most a couple of times a day, so without retention
    /// a Home Assistant restart would leave the sensor blank until the next
    /// morning. Zero is published explicitly rather than left absent — "no
    /// alarms slept through" is a real answer and an automation should be able
    /// to see it, which is the same reasoning as `publishRadioState`'s
    /// "stopped"/"none".
    ///
    /// The detail topic is JSON, the shape `radio_stations_available` already
    /// established, and is capped by `SleptThroughResolution.report` so a
    /// pathological night cannot publish an unbounded payload. `count` is
    /// always the honest total even when the list is capped.
    func publishSleptThroughToday(_ report: SleptThroughReport, settings: DeviceSettings) {
        guard isConnected else { return }
        let base = "\(settings.mqttTopicPrefix)/\(settings.sanitizedDeviceName)/sensor"
        publish(topic: "\(base)/slept_through_today", payload: "\(report.count)", retain: true)

        let iso = ISO8601DateFormatter()
        let rows: [[String: Any]] = report.entries.map { entry in
            [
                "name": entry.name,
                "index": entry.alarmIndex,
                "at": iso.string(from: entry.at),
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        publish(topic: "\(base)/slept_through_today_details", payload: json, retain: true)
        print("📡 Published slept-through today: \(report.count)")
    }
    
    // MARK: - Quick Alarm Sensor

    /// Publish Quick Alarm dashboard sensor — a single sensor for all ephemeral (quick) alarms.
    /// State: "none" when no quick alarms exist, or the fire time of the next quick alarm.
    func publishQuickAlarmState(quickAlarms: [Alarm], settings: DeviceSettings) {
        guard isConnected else { return }
        let deviceName = settings.sanitizedDeviceName
        let prefix = settings.mqttTopicPrefix
        let retain = settings.mqttPublishRetained

        let enabledQuick = quickAlarms.filter { $0.isEnabled }
        let activeQuick = enabledQuick.first
        let stateTopic = "\(prefix)/\(deviceName)/sensor/quick_alarm"
        let fireTimeTopic = "\(prefix)/\(deviceName)/sensor/quick_alarm_fire_time"
        let labelTopic = "\(prefix)/\(deviceName)/sensor/quick_alarm_label"
        let countTopic = "\(prefix)/\(deviceName)/sensor/quick_alarm_count"

        publish(topic: countTopic, payload: "\(enabledQuick.count)", retain: retain)

        if let quick = activeQuick, let fireDate = quick.nextFireDate() {
            let display = DateFormatter(); display.dateStyle = .short; display.timeStyle = .short
            publish(topic: stateTopic, payload: "active", retain: retain)
            publish(topic: fireTimeTopic, payload: ISO8601DateFormatter().string(from: fireDate), retain: retain)
            publish(topic: "\(fireTimeTopic)_display", payload: display.string(from: fireDate), retain: retain)
            publish(topic: labelTopic, payload: quick.label, retain: retain)
        } else {
            publish(topic: stateTopic, payload: "none", retain: retain)
            publish(topic: fireTimeTopic, payload: "none", retain: retain)
            publish(topic: "\(fireTimeTopic)_display", payload: "none", retain: retain)
            publish(topic: labelTopic, payload: "none", retain: retain)
        }
    }

    // MARK: - Per-Alarm Dynamic Entities

    /// Publish current state for a single alarm's sensors (index-based)
    func publishPerAlarmState(alarm: Alarm, sortOrder: Int, settings: DeviceSettings) {
        guard isConnected else { return }
        guard alarm.alarmIndex > 0 else { return }
        guard !alarm.isDetached else { return }
        guard !MQTTCommandHandler.shared.isSuppressingAlarmAccess else { return }
        
        let deviceName = settings.sanitizedDeviceName
        let prefix = settings.mqttTopicPrefix
        let index = alarm.alarmIndex
        let retain = settings.mqttPublishRetained
        let baseTopic = "\(prefix)/\(deviceName)/alarm/\(index)"
        
        // Mark alarm as existing — always publish retained so HA knows it's alive
        publish(topic: "\(baseTopic)/availability", payload: "online", retain: true)
        
        // Name
        publish(topic: "\(baseTopic)/name", payload: alarm.label, retain: retain)
        
        // Enabled
        publish(topic: "\(baseTopic)/enabled", payload: alarm.isEnabled ? "on" : "off", retain: retain)
        
        // State (per-alarm)
        let state: String
        if alarm.isSnoozed {
            state = "snoozed"
        } else {
            state = "idle"  // ringing/dismissed set by dedicated transition methods
        }
        publish(topic: "\(baseTopic)/state", payload: state, retain: retain)
        
        // Fire Time
        let isoFormatter = ISO8601DateFormatter()
        let displayFormatter = DateFormatter(); displayFormatter.dateStyle = .short; displayFormatter.timeStyle = .short
        if let nextFire = alarm.nextFireDate() {
            publish(topic: "\(baseTopic)/fire_time", payload: isoFormatter.string(from: nextFire), retain: retain)
            publish(topic: "\(baseTopic)/fire_time_display", payload: displayFormatter.string(from: nextFire), retain: retain)
        } else {
            publish(topic: "\(baseTopic)/fire_time", payload: "none", retain: retain)
            publish(topic: "\(baseTopic)/fire_time_display", payload: "none", retain: retain)
        }
        
        // Snooze Fire Time
        if alarm.isSnoozed, let snoozeUntil = alarm.snoozeUntil {
            publish(topic: "\(baseTopic)/snooze_fire_time", payload: isoFormatter.string(from: snoozeUntil), retain: retain)
            publish(topic: "\(baseTopic)/snooze_fire_time_display", payload: displayFormatter.string(from: snoozeUntil), retain: retain)
        } else {
            publish(topic: "\(baseTopic)/snooze_fire_time", payload: "none", retain: retain)
            publish(topic: "\(baseTopic)/snooze_fire_time_display", payload: "none", retain: retain)
        }
        
        // Days
        let days = alarm.safeRecurringDays
        if days.isEmpty {
            publish(topic: "\(baseTopic)/days", payload: "one-time", retain: retain)
        } else {
            let dayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let sortedDays = days.sorted()
            let dayString = sortedDays.compactMap { $0 >= 1 && $0 <= 7 ? dayNames[$0] : nil }.joined(separator: ",")
            publish(topic: "\(baseTopic)/days", payload: dayString, retain: retain)
        }
        
        // Mission — slot 1 only, unchanged, so existing dashboards and templates
        // keep reading what they always read.
        publish(topic: "\(baseTopic)/mission", payload: alarm.mission.type.rawValue.lowercased(), retain: retain)

        // Full mission sequence. An alarm can require up to five missions in
        // order and `…/mission` reports only the first, which made a
        // three-mission alarm indistinguishable from a one-mission alarm in HA.
        // `missions` is the ordered, comma-joined list of every slot that
        // actually gates dismissal (see Alarm.missionSequence — internal `.alert`
        // slots and a solo single-tap are excluded, exactly as they are in the
        // app), and `mission_count` is its length so automations can branch
        // without parsing.
        let sequence = alarm.missionSequence.map { $0.type.rawValue.lowercased() }
        publish(topic: "\(baseTopic)/missions",
                payload: sequence.isEmpty ? "none" : sequence.joined(separator: ","),
                retain: retain)
        publish(topic: "\(baseTopic)/mission_count", payload: "\(sequence.count)", retain: retain)

        // Tap-dismiss params (only meaningful for the Tap / "none" mission)
        if alarm.mission.type == .none {
            publish(topic: "\(baseTopic)/tap_dismiss_mode", payload: alarm.mission.tapDismissMode.rawValue.lowercased(), retain: retain)
            publish(topic: "\(baseTopic)/tap_count", payload: "\(alarm.mission.tapCount)", retain: retain)
            publish(topic: "\(baseTopic)/tap_hold_duration", payload: "\(Int(alarm.mission.tapHoldDuration))", retain: retain)
        }

        // Sound
        publish(topic: "\(baseTopic)/sound", payload: alarm.soundName, retain: retain)
        
        // Snoozes remaining (0 = unlimited → publish 999 so HA automations get a numeric value)
        let maxSnoozes = alarm.maxSnoozeCount ?? settings.defaultMaxSnoozeCount
        let snoozesRemaining = maxSnoozes == 0 ? 999 : max(0, maxSnoozes - alarm.snoozeCount)
        publish(topic: "\(baseTopic)/snoozes", payload: "\(snoozesRemaining)", retain: retain)
        
        // Volume (effective percentage)
        let volumePercent = Int(alarm.effectiveVolumeLevel(settings: settings) * 100)
        publish(topic: "\(baseTopic)/volume", payload: "\(volumePercent)%", retain: retain)
        
        // Vibrate (effective on/off)
        let vibrateOn = alarm.customVibrationEnabled ?? settings.alarmVibrationEnabled
        publish(topic: "\(baseTopic)/vibrate", payload: vibrateOn ? "on" : "off", retain: retain)
        
        // Fade In (duration in minutes, or "Off")
        let fadeInOn = alarm.effectiveFadeInEnabled(settings: settings)
        if fadeInOn {
            let fadeInMinutes = alarm.customFadeInDuration ?? settings.alarmFadeInDuration
            publish(topic: "\(baseTopic)/fade_in", payload: "\(fadeInMinutes) min", retain: retain)
        } else {
            publish(topic: "\(baseTopic)/fade_in", payload: "Off", retain: retain)
        }
        
        // Sort Order (1 = soonest/firing, higher = further away)
        publish(topic: "\(baseTopic)/sort_order", payload: "\(sortOrder)", retain: retain)

        // Swipe left/right commands — resolve UUID to command name
        if let leftID = alarm.swipeLeftCommandID, let uuid = UUID(uuidString: leftID),
           let cmd = settings.mqttCommands.first(where: { $0.id == uuid }) {
            publish(topic: "\(baseTopic)/swipe_left_command", payload: cmd.name, retain: retain)
        } else {
            publish(topic: "\(baseTopic)/swipe_left_command", payload: "None", retain: retain)
        }
        if let rightID = alarm.swipeRightCommandID, let uuid = UUID(uuidString: rightID),
           let cmd = settings.mqttCommands.first(where: { $0.id == uuid }) {
            publish(topic: "\(baseTopic)/swipe_right_command", payload: cmd.name, retain: retain)
        } else {
            publish(topic: "\(baseTopic)/swipe_right_command", payload: "None", retain: retain)
        }

        // Notes after-alarm page — the notes text and the assigned command
        // names (comma-joined), mirroring V1's per-alarm topics.
        let notesTrimmed = alarm.alarmScreenNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        publish(topic: "\(baseTopic)/notes", payload: notesTrimmed.isEmpty ? "None" : alarm.alarmScreenNotes, retain: retain)

        // Wake-up radio station for this alarm. Name (not URL) so dashboards and
        // notification templates read cleanly; "None" when unset, matching the
        // swipe-command topics rather than publishing an empty payload.
        // The after-alarm sequence, comma-joined in run order, or "none".
        // Without this an automation could set the steps but never read them
        // back — the same gap `missions` closed for mission sequences.
        let afterActions = alarm.afterAlarmActions.map(\.rawValue)
        publish(topic: "\(baseTopic)/after_alarm_actions",
                payload: afterActions.isEmpty ? "none" : afterActions.joined(separator: ","),
                retain: retain)

        publish(topic: "\(baseTopic)/radio_station",
                payload: alarm.radioStationName?.isEmpty == false ? alarm.radioStationName! : "None",
                retain: retain)
        let noteCommandNames = alarm.alarmScreenCommandIDs.compactMap { idString -> String? in
            guard let uuid = UUID(uuidString: idString) else { return nil }
            return settings.mqttCommands.first(where: { $0.id == uuid })?.name
        }
        publish(topic: "\(baseTopic)/commands",
                payload: noteCommandNames.isEmpty ? "None" : noteCommandNames.joined(separator: ","),
                retain: retain)

        // Button availability — dismiss available when ringing/snoozed,
        // snooze available when ringing/snoozed AND snooze is allowed for this alarm.
        let isActive = alarm.isSnoozed  // ringing state is handled by publishPerAlarmStateTransition
        publish(topic: "\(baseTopic)/dismiss_availability", payload: isActive ? "online" : "offline", retain: retain)
        
        let snoozeAllowed = isSnoozeAllowedForAlarm(alarm, snoozesRemaining: snoozesRemaining, settings: settings)
        publish(topic: "\(baseTopic)/snooze_availability", payload: (isActive && snoozeAllowed) ? "online" : "offline", retain: retain)
        
        // Skip available when idle, enabled, not skipped, not snoozed, skip mode enabled
        // Works for both recurring (skips next occurrence) and one-time (disables alarm)
        let skipAvailable = alarm.isEnabled && !alarm.isSkipped
            && !alarm.isSnoozed && alarm.effectiveSkipMode(settings: settings) != .disabled
        publish(topic: "\(baseTopic)/skip_availability", payload: skipAvailable ? "online" : "offline", retain: retain)
        
        // Kill Snoozed Alarm available only when snoozed
        publish(topic: "\(baseTopic)/kill_snoozed_availability", payload: alarm.isSnoozed ? "online" : "offline", retain: retain)

        // Unskip available only when alarm is currently skipped
        publish(topic: "\(baseTopic)/unskip_availability", payload: alarm.isSkipped ? "online" : "offline", retain: retain)
        
        // Morning weather
        publish(topic: "\(baseTopic)/morning_weather", payload: alarm.showWeatherAfterAlarm ? "on" : "off", retain: retain)

        // App links opened after dismiss/snooze
        publish(topic: "\(baseTopic)/dismiss_app_uri", payload: alarm.dismissAppURI ?? "None", retain: retain)
        publish(topic: "\(baseTopic)/snooze_app_uri", payload: alarm.snoozeAppURI ?? "None", retain: retain)
    }
    
    /// Publish a per-alarm state transition (ringing/snoozed/dismissed/idle)
    /// Also updates button availability: dismiss is available when ringing or snoozed,
    /// snooze is available when ringing or snoozed AND `snoozeAllowed` is true.
    func publishPerAlarmStateTransition(alarmIndex: Int, state: AlarmState, snoozeAllowed: Bool, settings: DeviceSettings) {
        guard isConnected, alarmIndex > 0 else { return }
        let deviceName = settings.sanitizedDeviceName
        let prefix = settings.mqttTopicPrefix
        let baseTopic = "\(prefix)/\(deviceName)/alarm/\(alarmIndex)"
        let retain = settings.mqttPublishRetained
        
        publish(topic: "\(baseTopic)/state", payload: state.rawValue, retain: retain)
        
        // Dismiss available when alarm is ringing or snoozed
        let isActive = (state == .ringing || state == .snoozed)
        publish(topic: "\(baseTopic)/dismiss_availability", payload: isActive ? "online" : "offline", retain: retain)
        
        // Snooze available when active AND snooze is allowed for this alarm
        publish(topic: "\(baseTopic)/snooze_availability", payload: (isActive && snoozeAllowed) ? "online" : "offline", retain: retain)
        
        // Skip always offline during transitions (ringing/snoozed/dismissed);
        // correct value set by publishPerAlarmState on next bulk refresh
        publish(topic: "\(baseTopic)/skip_availability", payload: "offline", retain: retain)
        
        // Kill Snoozed Alarm available only when snoozed
        publish(topic: "\(baseTopic)/kill_snoozed_availability", payload: (state == .snoozed) ? "online" : "offline", retain: retain)
        
        print("📡 Per-alarm state: alarm \(alarmIndex) → \(state.rawValue), dismiss: \(isActive ? "available" : "unavailable"), snooze: \(isActive && snoozeAllowed ? "available" : "unavailable")")
    }
    
    /// Publish per-alarm snoozes remaining
    func publishPerAlarmSnoozesRemaining(alarmIndex: Int, remaining: Int, settings: DeviceSettings) {
        guard isConnected, alarmIndex > 0 else { return }
        let deviceName = settings.sanitizedDeviceName
        let prefix = settings.mqttTopicPrefix
        let topic = "\(prefix)/\(deviceName)/alarm/\(alarmIndex)/snoozes"
        publish(topic: topic, payload: "\(remaining)", retain: settings.mqttPublishRetained)
    }
    
    /// Publish per-alarm snooze fire time
    func publishPerAlarmSnoozeFireTime(alarmIndex: Int, snoozeUntil: Date?, settings: DeviceSettings) {
        guard isConnected, alarmIndex > 0 else { return }
        let deviceName = settings.sanitizedDeviceName
        let prefix = settings.mqttTopicPrefix
        let topic = "\(prefix)/\(deviceName)/alarm/\(alarmIndex)/snooze_fire_time"
        if let snoozeUntil {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            publish(topic: topic, payload: formatter.string(from: snoozeUntil), retain: settings.mqttPublishRetained)
        } else {
            publish(topic: topic, payload: "none", retain: settings.mqttPublishRetained)
        }
    }
    
    /// Determine if snooze is allowed for an alarm based on its snooze mode,
    /// remaining snoozes, and mission type (HA mission with HA snooze always allows).
    func isSnoozeAllowedForAlarm(_ alarm: Alarm, snoozesRemaining: Int, settings: DeviceSettings) -> Bool {
        // HA mission with haSnoozeMode == .homeAssistant → snooze mode is not "disabled",
        // but still subject to maxSnoozeCount limit (falls through to snoozesRemaining check)
        
        // Snooze disabled for this alarm → never allow (HA snooze mode is never .disabled)
        if alarm.effectiveSnoozeMode(settings: settings) == .disabled {
            return false
        }
        // No snoozes remaining → don't allow
        if snoozesRemaining <= 0 {
            return false
        }
        return true
    }
    
    /// Clear the retained state topics this app version no longer publishes.
    ///
    /// The V1 alarm-screen notes widget is gone, so `sensor/alarm_notes`,
    /// `sensor/active_alarm_widget_command_1..4` and the per-alarm
    /// `alarm/<n>/widget_command_1..4` topics stopped being written. A topic that
    /// stops being written does NOT go away — the broker keeps serving the last
    /// retained value forever, so a dashboard built on the previous HACS
    /// integration keeps displaying notes and command names captured before the
    /// upgrade, indefinitely, with no hint they are stale. Publishing an empty
    /// retained payload is what actually deletes a retained message.
    ///
    /// Runs once per install (and again if the topic prefix or device name
    /// changes, since that is a different set of topics). Users who have already
    /// updated their HACS integration simply lose entities that no longer exist;
    /// users who have not get blanks instead of lies.
    func clearRetiredTopics(settings: DeviceSettings) {
        guard isConnected else { return }

        let prefix = settings.mqttTopicPrefix
        let deviceName = settings.sanitizedDeviceName
        let key = "didClearRetiredTopics"
        let stamp = "\(prefix)/\(deviceName)"
        guard UserDefaults.standard.string(forKey: key) != stamp else { return }

        let sensorBase = "\(prefix)/\(deviceName)/sensor"
        var cleared = 0
        for topic in ["alarm_notes",
                      "active_alarm_widget_command_1",
                      "active_alarm_widget_command_2",
                      "active_alarm_widget_command_3",
                      "active_alarm_widget_command_4"] {
            publish(topic: "\(sensorBase)/\(topic)", payload: "", retain: true)
            cleared += 1
        }

        // Per-alarm widget slots. Indices are never reused, so sweeping
        // 1..<nextAlarmIndex covers every alarm this device has ever published —
        // including ones already deleted, whose retained values would otherwise
        // outlive the alarm itself.
        let upperBound = max(settings.nextAlarmIndex, 1)
        for index in 1..<max(upperBound, 2) {
            for slot in 1...4 {
                publish(topic: "\(prefix)/\(deviceName)/alarm/\(index)/widget_command_\(slot)",
                        payload: "", retain: true)
                cleared += 1
            }
        }

        UserDefaults.standard.set(stamp, forKey: key)
        mqttLog("🧹 Cleared \(cleared) retired retained topic(s) for \(stamp)")
    }

    /// Fully remove a deleted alarm from the MQTT broker by clearing all retained topics.
    /// Publishing an empty payload with retain=true tells the broker to delete the retained message.
    func clearDeletedAlarm(alarmIndex: Int, settings: DeviceSettings) {
        guard isConnected, alarmIndex > 0 else { return }

        let prefix = settings.mqttTopicPrefix
        let deviceName = settings.sanitizedDeviceName
        let baseTopic = "\(prefix)/\(deviceName)/alarm/\(alarmIndex)"

        // Clear retained sensor state topics
        let suffixes = [
            "name", "enabled", "state", "fire_time", "snooze_fire_time", "days",
            "mission", "missions", "mission_count",
            "tap_dismiss_mode", "tap_count", "tap_hold_duration",
            "sound", "snoozes", "volume", "vibrate", "fade_in",
            "notes", "sort_order", "commands",
            "swipe_left_command", "swipe_right_command",
            "widget_command_1", "widget_command_2", "widget_command_3", "widget_command_4",
            "morning_weather", "dismiss_app_uri", "snooze_app_uri", "radio_station",
            "after_alarm_actions"
        ]
        for suffix in suffixes {
            publish(topic: "\(baseTopic)/\(suffix)", payload: "", retain: true)
        }

        // Clear button availability topics
        publish(topic: "\(baseTopic)/dismiss_availability", payload: "", retain: true)
        publish(topic: "\(baseTopic)/snooze_availability", payload: "", retain: true)
        publish(topic: "\(baseTopic)/skip_availability", payload: "", retain: true)
        publish(topic: "\(baseTopic)/kill_snoozed_availability", payload: "", retain: true)
        publish(topic: "\(baseTopic)/unskip_availability", payload: "", retain: true)

        // Clear availability last — empty + retain tells broker to delete the retained message
        publish(topic: "\(baseTopic)/availability", payload: "", retain: true)

        print("📡 Cleared all retained MQTT data for deleted alarm \(alarmIndex)")
    }
    
    // MARK: - Low-Level Publishing
    
    func publish(topic: String, payload: Any, retain: Bool = false) {
        guard let mqtt = client else {
            print("⚠️ Cannot publish - not connected")
            return
        }
        
        let message: String
        
        if let dict = payload as? [String: Any],
           let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: []),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            message = jsonString
        } else if let str = payload as? String {
            message = str
        } else {
            message = "\(payload)"
        }
        
        mqtt.publish(topic, withString: message, qos: .qos1, retained: retain)
        
        // Log the outbound publish to debug console and MQTT export log
        let truncated = message.count > 200 ? String(message.prefix(200)) + "…" : message
        mqttLog("📡 PUB \(topic) → \(truncated)")
    }
    
    /// Publish with a completion callback that fires when the broker ACKs (QoS 1).
    /// The callback is dispatched on the main queue.
    func publish(topic: String, payload: Any, retain: Bool = false, onAck: @escaping () -> Void) {
        guard let mqtt = client else {
            print("⚠️ Cannot publish - not connected")
            return
        }
        
        let message: String
        if let dict = payload as? [String: Any],
           let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: []),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            message = jsonString
        } else if let str = payload as? String {
            message = str
        } else {
            message = "\(payload)"
        }
        
        let msgID = UInt16(mqtt.publish(topic, withString: message, qos: .qos1, retained: retain))
        pendingPublishCallbacks[msgID] = onAck
        
        // Timeout: if no ACK in 5 seconds, clean up (don't fire callback)
        let capturedID = msgID
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.pendingPublishCallbacks.removeValue(forKey: capturedID)
        }
        
        let truncated = message.count > 200 ? String(message.prefix(200)) + "…" : message
        mqttLog("📡 PUB \(topic) → \(truncated)")
    }
    
    // MARK: - CocoaMQTTDelegate
    
    /// Validate the server certificate using the system trust store.
    /// Only certificates signed by a trusted CA are accepted — self-signed
    /// certificates will be rejected, preventing MITM attacks.
    func mqtt(_ mqtt: CocoaMQTT, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
        // Delegate callbacks arrive on main (see `delegateQueue` above), and
        // `SecTrustEvaluateWithError` can block for as long as a revocation
        // fetch takes. Evaluate off main and answer from there — CocoaMQTT only
        // requires that the completion handler is called, not where from.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var error: CFError?
            let isValid = SecTrustEvaluateWithError(trust, &error)
            let desc = (error as Error?)?.localizedDescription ?? "unknown error"
            DispatchQueue.main.async {
                if isValid {
                    self?.mqttLog("🔐 TLS certificate validated successfully")
                } else {
                    self?.mqttLog("❌ TLS certificate validation FAILED — \(desc). Use a valid CA-signed certificate (e.g., Let's Encrypt).")
                }
            }
            completionHandler(isValid)
        }
    }
    
    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        Task { @MainActor in
            self.connectionTimeoutTimer?.invalidate()
            if ack == .accept {
                self.mqttLog("✅ MQTT Connected to \(self.lastUsedHost ?? "unknown")")
                connectionState = .connected
                lastPongTime = Date()
                reconnectBackoffIndex = 0
                
                let settings = DeviceSettings.shared
                
                // Subscribe to inbound command topics (only if allowed)
                if settings.mqttAllowInboundCommands {
                    let commandTopic = "\(settings.mqttTopicPrefix)/\(settings.sanitizedDeviceName)/command/#"
                    mqtt.subscribe(commandTopic, qos: .qos1)
                    print("📥 Subscribed to: \(commandTopic)")
                    
                    // Subscribe to per-alarm command topics
                    let perAlarmCommandTopic = "\(settings.mqttTopicPrefix)/\(settings.sanitizedDeviceName)/alarm/+/command/#"
                    mqtt.subscribe(perAlarmCommandTopic, qos: .qos1)
                    print("📥 Subscribed to: \(perAlarmCommandTopic)")
                } else {
                    print("📥 Inbound commands disabled — skipping command subscription")
                }
                
                // Subscribe to HA birth message so we republish STATE when HA
                // restarts. Discovery is the HACS integration's job — the app
                // has never published a `homeassistant/.../config` topic.
                mqtt.subscribe("homeassistant/status", qos: .qos0)
                print("📥 Subscribed to: homeassistant/status")
                
                // Arm zone MQTT subscription — shared across all devices using the same zone name.
                // Zone "Home" → {prefix}/alarm/home/state. Any phone set to "Home" sees the same state.
                if settings.armButtonEnabled {
                    let armStateTopic = "\(settings.mqttTopicPrefix)/alarm/\(settings.armZoneSlug)/state"
                    mqtt.subscribe(armStateTopic, qos: .qos1)
                    print("📥 Subscribed to: \(armStateTopic)")
                }

                // Kids Sleep (al-2se): subscribe to the device-INDEPENDENT
                // subtree (sessions + roster) BEFORE the re-sync republish
                // below, so a peer's session/roster and any retained cancel are
                // delivered and reconciled instead of being resurrected by our
                // own republish. DEBUG-only: the feature is compiled out of
                // release, and gating on a non-empty roster would stop an empty
                // phone from ever bootstrapping from the broker.
                #if DEBUG
                let sleepTimerTopic = "\(settings.mqttTopicPrefix)/kids_sleep/#"
                mqtt.subscribe(sleepTimerTopic, qos: .qos1)
                print("📥 Subscribed to: \(sleepTimerTopic)")
                #endif

                // Publish online availability and initial state
                publishOnlineState(settings: settings)

                #if DEBUG
                // Clear the old per-device retained sleep-timer topics this
                // build no longer writes (one-time, flag-guarded). MUST run
                // AFTER publishOnlineState: same-connection publishes reach the
                // broker in order, so the new kids_sleep tree is populated
                // before the old tree empties — no instant where both are
                // empty and an OK-to-wake light goes dark on a sleeping kid.
                clearLegacySleepTimerTopics(settings: settings)
                #endif

                // One-time sweep of retained topics this version no longer writes,
                // so pre-upgrade values stop being served to HA forever.
                clearRetiredTopics(settings: settings)

                // Publish current alarm state — check if an alarm is actively
                // ringing before defaulting to idle. Without this check, reconnecting
                // MQTT during an active alarm would incorrectly broadcast "idle".
                let isAlarmActive = AlarmWindowManager.shared.isShowingAlarm || AlarmSoundPlayer.shared.isPlaying
                if isAlarmActive {
                    publishAlarmState(.ringing, settings: settings)
                } else {
                    publishAlarmState(.idle, settings: settings)
                }
                
                // Publish broker connection type and app version
                let brokerType = NetworkMonitor.shared.isOnHomeNetwork ? "internal" : "external"
                self.publishBrokerConnectionType(brokerType, settings: settings)
                self.publishAppVersion(settings: settings)
                self.publishMediaAlertVolume(settings.mediaAlertVolume, settings: settings)
                self.publishAlertVibrationEnabled(settings.alertVibrationEnabled, settings: settings)
                self.publishAlertLoopMedia(settings.alertLoopMedia, settings: settings)
                self.publishAlertLoopDelay(settings.alertLoopDelay, settings: settings)
                self.publishAlertDefaultSound(settings.alertDefaultSound, settings: settings)

                // Start monitoring hardware volume buttons so HA slider stays in sync
                self.startSystemVolumeMonitoring()

                // Notify AlarmListView to republish per-alarm state
                NotificationCenter.default.post(name: NSNotification.Name("MQTTDidConnect"), object: nil)
            } else {
                self.mqttLog("❌ MQTT Connection refused: \(ack.description)")
                connectionState = .error(ack.description)
                scheduleReconnect()
            }
        }
    }
    
    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {
        // Message published successfully
    }
    
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {
        if let callback = pendingPublishCallbacks.removeValue(forKey: id) {
            DispatchQueue.main.async {
                callback()
            }
        }
    }
    
    /// Decode a command payload into a JSON object.
    ///
    /// Strict JSON is tried FIRST and returned untouched. Only when that fails
    /// do we retry with Python/YAML literals rewritten (`True`/`False`/`None` →
    /// `true`/`false`/`null`), which is what HA YAML automations send when they
    /// omit the `>` block scalar. The rewrite is a whole-string regex and cannot
    /// tell a bare literal from the same word inside a quoted value, so it must
    /// never run on a payload that already parsed — otherwise notes, alert text
    /// and command names containing "None"/"True"/"False" get silently mangled.
    static func parseCommandPayload(_ payloadString: String) -> [String: Any]? {
        if let data = payloadString.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        let normalized = payloadString
            .replacingOccurrences(of: "\\bTrue\\b",  with: "true",  options: .regularExpression)
            .replacingOccurrences(of: "\\bFalse\\b", with: "false", options: .regularExpression)
            .replacingOccurrences(of: "\\bNone\\b",  with: "null",  options: .regularExpression)
        guard normalized != payloadString,
              let data = normalized.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    // MARK: - Command freshness

    /// How far from "now" a `ts`-bearing command may be before it is treated as
    /// a replay. Symmetric, so a clock skewed into the future is caught too.
    static let commandFreshnessWindow: TimeInterval = 60

    /// Age in seconds when the payload carries a parseable `ts` that falls
    /// OUTSIDE the freshness window; `nil` when the command should execute.
    ///
    /// `ts` stays OPTIONAL — an automation that has never sent one keeps working
    /// verbatim. This only decides what happens when one IS present, and it must
    /// decide it the same way on every inbound path: the check used to live in
    /// the JSON dispatcher alone, so per-alarm dismiss/snooze/skip — by far the
    /// most destructive commands — could be replayed freely.
    static func staleAge(inPayload payload: [String: Any]?) -> TimeInterval? {
        guard let ts = (payload?["ts"] as? NSNumber)?.doubleValue else { return nil }
        let age = Date().timeIntervalSince1970 - ts
        return abs(age) > commandFreshnessWindow ? age : nil
    }

    /// Same rule for the paths that only hold the raw payload string — per-alarm
    /// topics and the bare-switch forms. A payload that is not JSON ("ON", "12")
    /// has no `ts` and executes exactly as before.
    static func staleAge(inPayloadString payloadString: String) -> TimeInterval? {
        staleAge(inPayload: parseCommandPayload(payloadString))
    }

    /// True when the command must be dropped; logs the rejection with the topic,
    /// the `ts` and how far outside the window it fell.
    private func isStale(_ payload: [String: Any]?, topic: String) -> Bool {
        guard let age = Self.staleAge(inPayload: payload) else { return false }
        let ts = (payload?["ts"] as? NSNumber)?.doubleValue ?? 0
        mqttLog("⚠️ Stale command dropped: topic=\(topic) ts=\(Int(ts)) age=\(Int(age))s (window ±\(Int(Self.commandFreshnessWindow))s)")
        return true
    }

    private func isStale(payloadString: String, topic: String) -> Bool {
        isStale(Self.parseCommandPayload(payloadString), topic: topic)
    }

    /// Inbound command names we recognise, for TELEMETRY ONLY (this set never
    /// gates execution — the dispatcher's switch still owns that). Anything not
    /// listed reports as "unknown" rather than passing a broker-supplied string
    /// straight into analytics.
    private static let knownCommandNames: Set<String> = [
        "alert", "dismiss", "snooze", "skip", "unskip", "kill_snoozed",
        "create_alarm", "update_alarm", "delete_next_alarm", "delete_alarm",
        "delete_quick_alarm", "create_command", "delete_command",
        "set_media_alert_volume", "sleep_sound_start", "sleep_sound_stop",
        "sleep_sound_pause", "sleep_sound_resume", "sleep_sound_set_volume",
        "sleep_sound_change", "set_system_volume", "set_theme",
        "radio_start", "radio_stop", "radio_pause", "radio_resume",
        "app_persistence",
    ]

    private static func analyticsName(forCommand command: String) -> String {
        knownCommandNames.contains(command) ? command : "unknown"
    }

    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        print("📨 MQTT received: \(message.topic) - \(message.string ?? "")")
        
        // Request background time to process inbound command
        let taskID = UIApplication.shared.beginBackgroundTask {
            // Cleanup if time expires
        }
        
        let settings = DeviceSettings.shared

        // Handle HA birth message — republish all STATE when HA restarts
        // (discovery belongs to the HACS integration, not to us)
        if message.topic == "homeassistant/status" && message.string == "online" {
            print("🏠 Home Assistant came online — republishing state")
            Task { @MainActor in
                self.publishOnlineState(settings: settings)
                self.publishAlarmState(self.currentAlarmState, settings: settings)
                NotificationCenter.default.post(name: NSNotification.Name("MQTTDidConnect"), object: nil)
                UIApplication.shared.endBackgroundTask(taskID)
            }
            return
        }

        let devicePrefix = "\(settings.mqttTopicPrefix)/\(settings.sanitizedDeviceName)"

        // Handle arm state published by HA — HA is the source of truth.
        // Topic is zone-based (no device name) so all phones sharing the same zone
        // name receive the same retained state from HA and stay in sync.
        let armStateTopic = "\(settings.mqttTopicPrefix)/alarm/\(settings.armZoneSlug)/state"
        if message.topic == armStateTopic {
            let stateStr = message.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Task { @MainActor in
                if stateStr == "ON" || stateStr == "OFF" {
                    let armed = (stateStr == "ON")
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ArmStateChanged"),
                        object: nil,
                        userInfo: ["armed": armed]
                    )
                    self.mqttLog("📥 Arm state from HA: \(stateStr)")
                }
                UIApplication.shared.endBackgroundTask(taskID)
            }
            return
        }
        
        // Kids Sleep (al-2se): device-INDEPENDENT subtree shared across phones
        // (note: NO device segment). "roster" → the shared kid list;
        // "<slug>/state" → one kid's schedule. All reconcile decisions (adopt,
        // apply, republish, cancel, roster newer-wins) live in
        // SleepTimerSyncLogic; the store executes them on the main thread.
        let kidsSleepPrefix = "\(settings.mqttTopicPrefix)/kids_sleep/"
        if message.topic.hasPrefix(kidsSleepPrefix) {
            let remainder = String(message.topic.dropFirst(kidsSleepPrefix.count))
            let payload = message.string?.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            Task { @MainActor in
                if let payload {
                    if remainder == "roster" {
                        SleepTimerStore.shared.reconcileRemoteRoster(payload: payload)
                    } else if remainder.hasSuffix("/state") {
                        let slug = String(remainder.dropLast("/state".count))
                        if !slug.isEmpty, !slug.contains("/") {
                            SleepTimerStore.shared.reconcileRemoteSession(kidSlug: slug, payload: payload)
                        }
                    }
                }
                UIApplication.shared.endBackgroundTask(taskID)
            }
            return
        }

        let commandPrefix = "\(devicePrefix)/command/"
        let alarmPrefix = "\(devicePrefix)/alarm/"

        // Retained messages on command topics are replays — the broker redelivers
        // them on every subscribe, so executing them would repeat the command on
        // each reconnect. Status echo topics are exempt (the app publishes those
        // retained itself); state topics may still be retained.
        let isCommandTopic = (message.topic.hasPrefix(commandPrefix)
            || (message.topic.hasPrefix(alarmPrefix) && message.topic.contains("/command/")))
            && !message.topic.hasSuffix("/status")
        if isCommandTopic && message.retained {
            mqttLog("⚠️ Dropped retained message on command topic: \(message.topic)")
            UIApplication.shared.endBackgroundTask(taskID)
            return
        }

        // Safety check: ignore inbound commands if disabled
        guard settings.mqttAllowInboundCommands else {
            print("📥 Inbound commands disabled — ignoring: \(message.topic)")
            UIApplication.shared.endBackgroundTask(taskID)
            return
        }
        
        // Check if this is a per-alarm command (alarm/{index}/command/{dismiss|snooze})
        if message.topic.hasPrefix(alarmPrefix) {
            let remainder = String(message.topic.dropFirst(alarmPrefix.count))
            // Expected format: {index}/command/{dismiss|snooze}
            let parts = remainder.split(separator: "/", maxSplits: 3)
            if parts.count >= 3 && parts[1] == "command" {
                let action = String(parts[2])
                // Freshness, when the payload carries a `ts`. Per-alarm dismiss,
                // snooze and skip are the most destructive commands there are;
                // they used to `return` before the check the dispatcher applied.
                if isStale(payloadString: message.string ?? "", topic: message.topic) {
                    UIApplication.shared.endBackgroundTask(taskID)
                    return
                }
                if let alarmIndex = Int(parts[0]) {
                    Task { @MainActor in
                        switch action {
                        case "dismiss":
                            MQTTCommandHandler.shared.handlePerAlarmDismiss(alarmIndex: alarmIndex)
                        case "snooze":
                            MQTTCommandHandler.shared.handlePerAlarmSnooze(alarmIndex: alarmIndex)
                        case "skip":
                            MQTTCommandHandler.shared.handlePerAlarmSkip(alarmIndex: alarmIndex)
                        case "kill_snoozed":
                            MQTTCommandHandler.shared.handlePerAlarmKillSnoozed(alarmIndex: alarmIndex)
                        case "unskip":
                            MQTTCommandHandler.shared.handlePerAlarmUnskip(alarmIndex: alarmIndex)
                        case "enabled":
                            let payloadStr = String(bytes: message.payload, encoding: .utf8) ?? ""
                            // Fail-closed is deliberate — anything that isn't the
                            // accepted "ON" disables the alarm rather than guessing.
                            // But a payload that is neither "ON" nor a recognised OFF
                            // form is almost certainly an automation bug, so name it.
                            self.warnIfUnrecognizedSwitchPayload(payloadStr, topic: message.topic)
                            MQTTCommandHandler.shared.handlePerAlarmEnabled(alarmIndex: alarmIndex, enabled: payloadStr == "ON")
                        default:
                            print("⚠️ Unknown per-alarm command: \(action) for index \(alarmIndex)")
                        }
                        UIApplication.shared.endBackgroundTask(taskID)
                    }
                } else {
                    print("⚠️ Invalid alarm index in per-alarm command: \(parts[0])")
                    UIApplication.shared.endBackgroundTask(taskID)
                }
                return
            }
        }
        
        guard message.topic.hasPrefix(commandPrefix) else {
            UIApplication.shared.endBackgroundTask(taskID)
            return
        }
        
        let command = String(message.topic.dropFirst(commandPrefix.count))
        // Ignore status feedback topics (e.g. command/lr_shutdown/status) — those are
        // published by the app itself and looped back by the broker; they are not inbound commands.
        guard !command.hasSuffix("/status") else {
            UIApplication.shared.endBackgroundTask(taskID)
            return
        }

        // Treat nil or empty/whitespace payloads as an empty JSON object so
        // dashboard buttons that send no payload don't fail the JSON guard below.
        let rawPayload = message.string ?? ""
        let payloadString = rawPayload.trimmingCharacters(in: .whitespaces).isEmpty ? "{}" : rawPayload
        
        // Handle simple ON/OFF switch commands before JSON parsing
        let payloadUpper = payloadString.trimmingCharacters(in: .whitespaces).uppercased()
        if command == "alert_vibrate" || command == "alert_loop_media" || command == "alert_loop_delay" {
            // Bare "ON"/"OFF"/"12" has no `ts` and executes as before; a JSON
            // payload carrying one is held to the same window as everything else.
            if isStale(payloadString: payloadString, topic: message.topic) {
                UIApplication.shared.endBackgroundTask(taskID)
                return
            }
            Task { @MainActor in
                let handler = MQTTCommandHandler.shared
                switch command {
                case "alert_vibrate":
                    self.warnIfUnrecognizedSwitchPayload(payloadString, topic: message.topic)
                    handler.handleAlertVibrateCommand(enabled: payloadUpper == "ON")
                case "alert_loop_media":
                    self.warnIfUnrecognizedSwitchPayload(payloadString, topic: message.topic)
                    handler.handleAlertLoopMediaCommand(enabled: payloadUpper == "ON")
                case "alert_loop_delay":
                    if let seconds = Double(payloadString.trimmingCharacters(in: .whitespaces)) {
                        handler.handleAlertLoopDelayCommand(seconds: seconds)
                    } else {
                        self.mqttLog("⚠️ Ignored non-numeric alert_loop_delay payload on \(message.topic): '\(payloadString)'")
                    }
                default: break
                }
                UIApplication.shared.endBackgroundTask(taskID)
            }
            return
        }

        // `app_persistence` accepts a bare switch payload as well as JSON. The
        // bare form ("ON"/"OFF") is what a Home Assistant switch entity
        // publishes and is handled here; the JSON form
        // (`{"enabled": true}`) falls through to the dispatcher below. Both
        // spellings exist because the switch is the primary surface but a
        // hand-written `mqtt.publish` — which is how everything else on this
        // device is driven — naturally sends JSON, and rejecting one of the two
        // would be a trap rather than a contract.
        //
        // `parseAppPersistenceMode` wraps the same on/off parse, so "ON"/"OFF"
        // behave exactly as before; a bare "DYNAMIC" is simply also understood.
        if command == "app_persistence",
           let desired = MQTTCommandHandler.parseAppPersistenceMode(payloadString) {
            if isStale(payloadString: payloadString, topic: message.topic) {
                UIApplication.shared.endBackgroundTask(taskID)
                return
            }
            Task { @MainActor in
                MQTTCommandHandler.shared.handleAppPersistenceCommand(mode: desired)
                UIApplication.shared.endBackgroundTask(taskID)
            }
            return
        }

        // Parse the payload as JSON. PARSE FIRST, normalise only on failure:
        // the Python-literal rewrite below is a blunt regex over the whole
        // string, so running it up front corrupts legitimate TEXT that happens
        // to contain those words — `{"notes": "None of the trash goes out"}`
        // became "null of the trash goes out". A well-formed JSON payload now
        // never touches the rewrite.
        guard let payload = Self.parseCommandPayload(payloadString) else {
            print("❌ Invalid JSON payload for command: \(command)")
            UIApplication.shared.endBackgroundTask(taskID)
            return
        }

        // Optional freshness check: a `ts` field (unix epoch seconds) rejects
        // stale/replayed commands. Commands without `ts` still execute.
        // Shared with the per-alarm and bare-switch paths above — see `isStale`.
        if isStale(payload, topic: message.topic) {
            UIApplication.shared.endBackgroundTask(taskID)
            return
        }

        Task { @MainActor in
            let handler = MQTTCommandHandler.shared

            // One call covers every inbound command type. `command` arrives off
            // the BROKER, so it is clamped to the known set before it reaches
            // analytics — an unbounded remotely-supplied string would blow GA4's
            // cardinality limits and would let anyone with broker access write
            // arbitrary values into our telemetry.
            Analytics.shared.log(.mqttCommandReceived(commandType: Self.analyticsName(forCommand: command)))

            switch command {
            case "alert":
                await handler.handleSecurityAlert(payload: payload)
            case "dismiss":
                handler.handleDismissCommand(payload: payload)
            case "snooze":
                handler.handleSnoozeCommand(payload: payload)
            case "skip":
                handler.handleSkipNextAlarm()
            case "unskip":
                handler.handleUnskipNextAlarm()
            case "kill_snoozed":
                if let activeIndex = self.activeAlarmIndex {
                    handler.handlePerAlarmKillSnoozed(alarmIndex: activeIndex)
                } else {
                    print("⚠️ Kill snoozed command: no active alarm")
                }
            case "create_alarm":
                await handler.handleCreateAlarm(payload: payload)
            case "update_alarm":
                await handler.handleUpdateAlarm(payload: payload)
            case "delete_next_alarm":
                await handler.handleDeleteNextAlarm()
            case "delete_alarm":
                await handler.handleDeleteAlarm(payload: payload)
            case "delete_quick_alarm":
                handler.handleDeleteQuickAlarm()
            case "create_command":
                handler.handleCreateCommand(payload: payload)
            case "delete_command":
                handler.handleDeleteCommand(payload: payload)
            case "set_media_alert_volume":
                handler.handleSetMediaAlertVolume(payload: payload)
            case "radio_start":
                handler.handleRadioStart(payload: payload)
            case "radio_stop":
                handler.handleRadioStop(payload: payload)
            case "radio_pause":
                handler.handleRadioPause(payload: payload)
            case "radio_resume":
                handler.handleRadioResume(payload: payload)
            case "sleep_sound_start":
                handler.handleSleepSoundStart(payload: payload)
            case "sleep_sound_stop":
                handler.handleSleepSoundStop()
            case "sleep_sound_pause":
                handler.handleSleepSoundPause()
            case "sleep_sound_resume":
                handler.handleSleepSoundResume()
            case "sleep_sound_set_volume":
                handler.handleSleepSoundSetVolume(payload: payload)
            case "sleep_sound_change":
                handler.handleSleepSoundChange(payload: payload)
            case "set_system_volume":
                handler.handleSetSystemVolume(payload: payload)
            case "set_theme":
                handler.handleSetTheme(payload: payload)
            case "app_persistence":
                handler.handleAppPersistenceCommand(payload: payload)
            default:
                print("⚠️ Unknown MQTT command: \(command)")
            }
            
            UIApplication.shared.endBackgroundTask(taskID)
        }
    }
    
    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {
        print("✅ MQTT subscribed to topics")
    }
    
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {
        print("🔕 MQTT unsubscribed from topics")
    }
    
    func mqttDidPing(_ mqtt: CocoaMQTT) {
        // Keepalive ping sent
    }
    
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {
        lastPongTime = Date()
    }
    
    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        Task { @MainActor in
            self.connectionTimeoutTimer?.invalidate()
            if let error = err {
                self.mqttLog("❌ MQTT disconnected: \(error.localizedDescription)")
                connectionState = .error(error.localizedDescription)
                
                if !isIntentionalDisconnect {
                    scheduleReconnect()
                }
            } else {
                self.mqttLog("🔌 MQTT disconnected (intentional: \(isIntentionalDisconnect))")
                if !isIntentionalDisconnect {
                    connectionState = .disconnected
                    scheduleReconnect()
                }
            }
        }
    }
    
    func mqtt(_ mqtt: CocoaMQTT, didStateChangeTo state: CocoaMQTTConnState) {
        mqttLog("🔄 MQTT state: \(state)")
    }
    
    // MARK: - Alarm Sorting
    
    /// Sort alarms for display: ringing/snoozed first, then enabled by next fire time,
    /// then disabled by time, then completed one-time alarms last.
    static func sortAlarmsForDisplay(_ alarms: [Alarm]) -> [Alarm] {
        // If an alarm delete is in progress, return an empty array to avoid
        // accessing lazy properties on invalidated backing data.
        guard !MQTTCommandHandler.shared.isSuppressingAlarmAccess else { return [] }
        // Filter out detached alarms first — accessing lazy properties (like
        // recurringDays) on a deleted SwiftData object causes a fatal crash.
        return alarms.filter { !$0.isDetached }.sorted { a1, a2 in
            // Priority 0: Ringing/snoozed alarms first
            let active1 = a1.isSnoozed
            let active2 = a2.isSnoozed
            if active1 != active2 { return active1 }

            // Priority 1: Completed one-time alarms to bottom
            let completed1 = !a1.isRecurring && a1.lastFireDate != nil
            let completed2 = !a2.isRecurring && a2.lastFireDate != nil
            if completed1 != completed2 { return completed2 }

            // Priority 2: Enabled before disabled
            if a1.isEnabled != a2.isEnabled { return a1.isEnabled }

            // Priority 3: Enabled alarms sorted by next fire time (soonest first)
            if a1.isEnabled && a2.isEnabled {
                let f1 = a1.nextFireDate()
                let f2 = a2.nextFireDate()
                if let f1, let f2 { return f1 < f2 }
                if f1 != nil { return true }
                if f2 != nil { return false }
            }

            // Priority 4: Disabled alarms sorted by time of day
            return a1.time < a2.time
        }
    }
}

// ✅ Real MQTT Manager is now active!


