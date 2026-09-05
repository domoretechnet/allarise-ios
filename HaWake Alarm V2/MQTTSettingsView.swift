//
//  MQTTSettingsView.swift
//  HaWake Alarm V2
//
//  MQTT configuration as a dedicated settings page with clear sections.
//

import CoreLocation
import SwiftData
import SwiftUI

struct MQTTSettingsView: View {
    @Bindable var settings: DeviceSettings
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { settings.appAccent(for: colorScheme) }
    @Query private var alarms: [Alarm]
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingAddSSIDSheet = false
    @State private var isTesting = false
    @State private var testResult: MQTTTestResult?
    @State private var showingResetAlarmIDConfirmation = false
    
    // Snapshot of settings on appear for dirty tracking
    @State private var initialSnapshot = MQTTSnapshot()
    
    enum MQTTTestResult: Equatable {
        case success
        case failure(String)
    }
    
    /// Captures MQTT-related settings for change detection.
    private struct MQTTSnapshot: Equatable {
        var topicPrefix = ""
        var deviceName = ""
        var allowInbound = false
        var internalHost = ""
        var internalPort = 0
        var externalHost = ""
        var externalPort = 0
        var username = ""
        var password = ""
        var homeSSIDs: [String] = []
    }
    
    private func snapshot() -> MQTTSnapshot {
        MQTTSnapshot(
            topicPrefix: settings.mqttTopicPrefix,
            deviceName: settings.deviceName,
            allowInbound: settings.mqttAllowInboundCommands,
            internalHost: settings.mqttInternalHost,
            internalPort: settings.mqttInternalPort,
            externalHost: settings.mqttExternalHost,
            externalPort: settings.mqttExternalPort,
            username: settings.mqttUsername,
            password: settings.mqttPassword,
            homeSSIDs: settings.homeSSIDs
        )
    }
    
    private var hasChanges: Bool {
        snapshot() != initialSnapshot
    }
    
    var body: some View {
        Form {
            // MARK: - MQTT Identity
            Section {
                LabeledContent("Topic Prefix") {
                    TextField("Prefix", text: $settings.mqttTopicPrefix)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
                
                LabeledContent("Device Name") {
                    TextField("Device Name", text: $settings.deviceName)
                        .multilineTextAlignment(.trailing)
                }
                
                Toggle(isOn: $settings.mqttAllowInboundCommands) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow Inbound Commands")
                        Text("Let Home Assistant create alarms, trigger alerts, and dismiss alarms")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: settings.mqttAllowInboundCommands) { _, _ in
                    if settings.mqttEnabled {
                        HAIntegrationRouter.shared.disconnect()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            HAIntegrationRouter.shared.connect(settings: settings)
                        }
                    }
                }

            } header: {
                Text("MQTT Identity")
            } footer: {
                Text("Your topic prefix and device name define how this device appears on your MQTT broker.")
            }
            
            // MARK: - Internal Broker
            Section {
                LabeledContent("Host") {
                    TextField(
                        "192.168.1.100",
                        text: $settings.mqttInternalHost
                    )
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .onSubmit {
                        triggerLocalNetworkPromptIfReady()
                    }
                    .onChange(of: settings.mqttInternalHost) { oldValue, newValue in
                        if !newValue.isEmpty && oldValue.isEmpty && !settings.homeSSIDs.isEmpty {
                            triggerLocalNetworkPromptIfReady()
                        }
                    }
                }
                
                LabeledContent("Port") {
                    TextField(
                        "1883",
                        value: $settings.mqttInternalPort,
                        format: .number.grouping(.never)
                    )
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                }

                Toggle(isOn: $settings.mqttUseTLS) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use TLS")
                        Text("Recommended — encrypts the connection to the home-network broker")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: settings.mqttUseTLS) { _, _ in
                    if settings.mqttEnabled {
                        HAIntegrationRouter.shared.forceReconnect(settings: settings)
                    }
                }
            } header: {
                Label("Internal Broker", systemImage: "house.fill")
            } footer: {
                // New setups start with TLS on (DeviceSettings seeds it only when
                // no broker has ever been configured), so the port reminder matters
                // here: the default 1883 is the plaintext port and a TLS connection
                // to it will simply fail.
                Text("Used when connected to a home WiFi network. TLS applies to the home-network broker only — external connections always use TLS. TLS is recommended; brokers typically serve it on port 8883, while 1883 is the unencrypted port.")
            }
            .listSectionSpacing(32)
            
            // MARK: - External Broker
            Section {
                LabeledContent("Host") {
                    TextField(
                        "mqtt.example.com",
                        text: $settings.mqttExternalHost
                    )
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                }
                
                LabeledContent("Port") {
                    TextField(
                        "8883",
                        value: $settings.mqttExternalPort,
                        format: .number.grouping(.never)
                    )
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
                }
                
                Toggle(isOn: $settings.forceExternalConnection) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Always Use External")
                        Text("Bypass home network detection and always connect to the external broker")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: settings.forceExternalConnection) { _, _ in
                    if settings.mqttEnabled {
                        HAIntegrationRouter.shared.forceReconnect(settings: settings)
                    }
                }
                
            } header: {
                Label("External Broker", systemImage: "globe")
            } footer: {
                Text("Used when away from home WiFi. External connections always use \(Image(systemName: "lock.fill"))TLS.")
            }
            .listSectionSpacing(32)
            
            // MARK: - Authentication
            Section {
                LabeledContent("Username") {
                    TextField("Username", text: $settings.mqttUsername)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .textContentType(.username)
                }
                
                LabeledContent("Password") {
                    SecureField("Password", text: $settings.mqttPassword)
                        .multilineTextAlignment(.trailing)
                        .textContentType(.password)
                }

                // A Keychain write that fails leaves the credential working for
                // this session but gone after a relaunch. Say so here, at the
                // moment of the action, rather than letting MQTT quietly fail to
                // authenticate on the next cold start.
                if settings.mqttCredentialSaveFailed {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Credentials not saved securely")
                            Text("iOS refused the Keychain write. These credentials work now but will be lost when the app restarts — try again, or restart the device if it keeps failing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }


                // Test Connection
                Button {
                    testMQTTConnection()
                } label: {
                    HStack {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                            Text("Testing...")
                        } else if let result = testResult {
                            switch result {
                            case .success:
                                Image(systemName: "checkmark.circle.fill")
                                Text("Connected!")
                            case .failure(let message):
                                Image(systemName: "xmark.circle.fill")
                                Text(message)
                            }
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text("Test Connection")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .animation(.easeInOut(duration: 0.2), value: testResult == nil)
                }
                .foregroundStyle(testButtonColor)
                .disabled(isTesting || testResult != nil)
            } header: {
                Label("Authentication", systemImage: "lock.fill")
            }
            .listSectionSpacing(32)
            
            // MARK: - Home WiFi Networks
            Section {
                // Location permission warning
                if !settings.suppressLocationPermissionNag && locationPermissionNeeded {
                    HStack(spacing: 12) {
                        Image(systemName: "location.slash")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Location Permission Required")
                                .font(.subheadline)
                            Text("WiFi network detection needs location access to determine your current network.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    
                    Button("Don't Show Again", role: .destructive) {
                        settings.suppressLocationPermissionNag = true
                    }
                    .font(.caption)
                }
                
                // SSID list
                if settings.homeSSIDs.isEmpty {
                    Text("No home networks configured")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(settings.homeSSIDs, id: \.self) { ssid in
                        HStack {
                            Image(systemName: "wifi")
                                .foregroundStyle(accent)
                            Text(ssid)
                            
                            Spacer()
                            
                            if NetworkMonitor.shared.currentSSID == ssid {
                                Text("Connected")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(.green))
                            }
                            
                            Button(role: .destructive) {
                                removeSSID(ssid)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                
                Button {
                    showingAddSSIDSheet = true
                } label: {
                    Label("Add Network", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Home WiFi Networks")
            } footer: {
                Text("Add your home WiFi networks so the app knows when to use the internal broker vs. the external broker.")
            }
            
            // MARK: - Debug
            #if DEBUG
            Section {
                Toggle(isOn: $settings.debugForceHomeNetwork) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Force Home Network (DEBUG)")
                        Text("Bypass WiFi detection, use internal broker")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Debug", systemImage: "ladybug.fill")
            }
            #endif
            
            // MARK: - Resources
            Section {
                Link(destination: AppLinks.mqttBuilder) {
                    HStack {
                        Image(systemName: "book.fill")
                            .foregroundStyle(accent)
                        Text("MQTT Documentation")
                            .foregroundStyle(accent)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(accent)
                    }
                }
            } header: {
                Text("Resources")
            }
            
            // MARK: - Danger Zone
            Section {
                Button(role: .destructive) {
                    showingResetAlarmIDConfirmation = true
                } label: {
                    Label("Reset MQTT Alarm IDs", systemImage: "arrow.counterclockwise")
                        .symbolRenderingMode(.multicolor)
                        .foregroundStyle(.red)
                }
                .alert(
                    "Renumber every alarm?",
                    isPresented: $showingResetAlarmIDConfirmation
                ) {
                    Button("Renumber", role: .destructive) {
                        resetMQTTAlarmIDs()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    // The previous wording said only that NEW alarms "may reuse
                    // old IDs", which understated it: every existing alarm is
                    // renumbered immediately, in time order. MQTT alarm IDs exist
                    // precisely so Home Assistant keeps working when an alarm is
                    // renamed — so silently repointing them is the one failure
                    // this feature is meant to prevent. Say so plainly.
                    Text(resetAlarmIDWarning)
                }
            } footer: {
                Text("Next MQTT alarm ID: \(settings.nextAlarmIndex)")
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("MQTT Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if hasChanges {
                    Button("Save") {
                        // Reconnect MQTT with updated settings
                        if settings.mqttEnabled {
                            HAIntegrationRouter.shared.disconnect()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                HAIntegrationRouter.shared.connect(settings: settings)
                            }
                        }
                        dismiss()
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .onAppear {
            initialSnapshot = snapshot()
        }
        .sheet(isPresented: $showingAddSSIDSheet) {
            triggerLocalNetworkPromptIfReady()
        } content: {
            AddSSIDSheet(settings: settings)
        }
    }
    
    // MARK: - Helpers
    
    private var testButtonColor: Color {
        switch testResult {
        case .success: return .green
        case .failure: return .red
        // `.accentColor` reads the (empty) asset catalog, not the app tint, so the
        // idle Test button stayed blue under a custom accent (al-nl9).
        case nil: return accent
        }
    }
    
    private var locationPermissionNeeded: Bool {
        let status = NetworkMonitor.shared.locationAuthorizationStatus
        return status == .denied || status == .restricted
    }
    
    private func removeSSID(_ ssid: String) {
        settings.homeSSIDs.removeAll { $0 == ssid }
        NetworkMonitor.shared.refreshSSID()
    }
    
    private func triggerLocalNetworkPromptIfReady() {
        guard settings.mqttEnabled,
              !settings.mqttInternalHost.isEmpty,
              !settings.homeSSIDs.isEmpty else { return }
        
        HAIntegrationRouter.shared.disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            HAIntegrationRouter.shared.connect(settings: settings)
        }
    }
    
    private func testMQTTConnection() {
        isTesting = true
        testResult = nil
        
        HAIntegrationRouter.shared.disconnect()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            HAIntegrationRouter.shared.connect(settings: settings)
            
            var checks = 0
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                checks += 1
                
                switch HAIntegrationRouter.shared.connectionState {
                case .connected:
                    timer.invalidate()
                    isTesting = false
                    showResult(.success)
                case .error(let msg):
                    timer.invalidate()
                    isTesting = false
                    showResult(.failure(msg))
                case .disconnected where checks > 4:
                    timer.invalidate()
                    isTesting = false
                    showResult(.failure("Connection failed — check host and port"))
                default:
                    break
                }
                
                if checks >= 20 {
                    timer.invalidate()
                    isTesting = false
                    showResult(.failure("Connection timed out"))
                }
            }
        }
    }
    
    private func showResult(_ result: MQTTTestResult) {
        withAnimation { testResult = result }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { testResult = nil }
        }
    }
    
    /// The Danger Zone warning. Built from the live alarm list so the user sees
    /// the actual renumbering that is about to happen, not an abstract caution —
    /// "Gym becomes 2" is checkable against their own automations in a way that
    /// "IDs may be reused" is not.
    private var resetAlarmIDWarning: String {
        let affected = alarms.filter { !$0.isEphemeral }.sorted { $0.time < $1.time }
        var text = """
        Every alarm is renumbered right now, in time order — not just new ones.

        Home Assistant entities are keyed on these IDs (sensor.…_alarm_3_fire_time), \
        so any automation, script or dashboard card referring to a specific alarm \
        will point at a DIFFERENT alarm afterwards. Renaming an alarm is safe; this is not.
        """
        if !affected.isEmpty {
            let preview = affected.prefix(5).enumerated().map { i, a -> String in
                let name = a.label.isEmpty ? "Untitled" : a.label
                return a.alarmIndex == i + 1 ? "• \(name): \(i + 1) (unchanged)"
                                             : "• \(name): \(a.alarmIndex) → \(i + 1)"
            }.joined(separator: "\n")
            let more = affected.count > 5 ? "\n• …and \(affected.count - 5) more" : ""
            text += "\n\n\(preview)\(more)"
        }
        text += "\n\nOnly do this if your Home Assistant automations are already broken, or you have none yet."
        return text
    }

    private func resetMQTTAlarmIDs() {
        // Clean up retained state for current indices
        if settings.mqttEnabled {
            for alarm in alarms where alarm.alarmIndex > 0 {
                MQTTManager.shared.clearDeletedAlarm(alarmIndex: alarm.alarmIndex, settings: settings)
            }
        }
        
        // Reassign all existing alarms with sequential IDs starting from 1
        let sorted = alarms.sorted { $0.time < $1.time }
        for (index, alarm) in sorted.enumerated() {
            alarm.alarmIndex = index + 1
        }
        settings.nextAlarmIndex = sorted.count + 1
        
        // Re-publish state with new indices
        if settings.mqttEnabled {
            HAIntegrationRouter.shared.publishCurrentAlarmState(alarms: alarms, settings: settings)
        }
    }
}

#Preview {
    NavigationStack {
        MQTTSettingsView(settings: DeviceSettings.shared)
    }
}
