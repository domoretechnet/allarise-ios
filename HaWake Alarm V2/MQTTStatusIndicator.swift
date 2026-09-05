//
//  MQTTStatusIndicator.swift
//  HaWake Alarm V2
//
//  Shows MQTT connection status. Declares `MQTTStatusDetailView`, the sheet
//  presented from AlarmListView. The old navigation-bar `MQTTStatusIndicator`
//  view was removed 2026-08-03 (audit DEAD-01) — it had no construction site.
//

import SwiftUI

struct MQTTStatusDetailView: View {
    var mqttManager: HAIntegrationRouter
    let settings: DeviceSettings
    /// Called when the user taps integration settings to open Settings
    var onOpenSettings: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var connectedColor: Color {
        settings.appAccent(for: colorScheme)
    }
    
    private var modeLabel: String {
        "MQTT"
    }
    
    var body: some View {
        NavigationStack {
            List {
                // MARK: - Connection Status (no separators)
                Section {
                    VStack(spacing: 16) {
                        // Status row with reconnect
                        HStack {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 14, height: 14)
                            
                            Text(statusText)
                                .font(.headline)
                            
                            Spacer()
                            
                            Button {
                                mqttManager.forceReconnect(settings: settings)
                            } label: {
                                Label("Reconnect", systemImage: "arrow.clockwise")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.borderless)
                        }
                        
                        // Details
                        VStack(spacing: 8) {
                            if let server = currentServer {
                                detailRow(label: "Broker", value: server)
                            }
                            
                            detailRow(label: "Network", value: NetworkMonitor.shared.connectionDescription)
                            
                            #if DEBUG
                            if settings.debugForceHomeNetwork {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .font(.caption)
                                    Text("Debug: Forced Home Network")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                    Spacer()
                                }
                            }
                            #endif
                        }
                    }
                    .listRowSeparator(.hidden)
                } header: {
                    Text("Connection Status")
                }

                // MARK: - Status Indicator Key
                Section {
                    VStack(spacing: 10) {
                        HStack(spacing: 16) {
                            indicatorDot(color: connectedColor, label: "Connected")
                            indicatorDot(color: .yellow, label: "Connecting")
                        }
                        HStack(spacing: 16) {
                            indicatorDot(color: .gray, label: "Disconnected")
                            indicatorDot(color: .orange, label: "Not Configured")
                        }
                        HStack(spacing: 16) {
                            indicatorDot(color: .red, label: "Error")
                            Spacer()
                        }
                    }
                    .listRowSeparator(.hidden)
                } header: {
                    Text("Status Indicator Key")
                }

            }
            .navigationTitle("\(modeLabel) Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
    }
    
    // MARK: - Helper Views
    
    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
        }
    }

    private func indicatorDot(color: Color, label: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusColor: Color {
        switch mqttManager.connectionState {
        case .connected:    return connectedColor
        case .connecting:   return .yellow
        case .disconnected: return .gray
        case .notConfigured: return .orange
        case .error:        return .red
        }
    }

    private var statusText: String {
        mqttManager.connectionState.description
    }
    
    private var currentServer: String? {
        let config = NetworkMonitor.shared.getBrokerConfig(settings: settings)
        guard !config.host.isEmpty else { return nil }
        return "\(config.host):\(config.port)"
    }
}
