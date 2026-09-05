//
//  INTEGRATION_EXAMPLE.swift
//  HaWake Alarm V2
//
//  Example of how to integrate background refresh monitoring into your settings view
//

/*

// EXAMPLE 1: Add to Settings/About screen
// If you have a settings view, add a navigation link:

import SwiftUI

struct SettingsView: View {
    @ObservedObject var checker = BackgroundRefreshStatusChecker.shared
    
    var body: some View {
        List {
            Section("System") {
                NavigationLink {
                    BackgroundRefreshDebugView()
                } label: {
                    HStack {
                        Label("Background Refresh", systemImage: "arrow.clockwise")
                        Spacer()
                        if !checker.isBackgroundRefreshEnabled {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            
            Section("Other Settings") {
                // Your other settings...
            }
        }
        .navigationTitle("Settings")
    }
}

// EXAMPLE 2: Add inline status to alarm list
// Show status at the bottom of your alarm list:

struct AlarmListView: View {
    @ObservedObject var checker = BackgroundRefreshStatusChecker.shared
    @Query var alarms: [Alarm]
    
    var body: some View {
        List {
            // Your alarm cells...
            
            // Status at bottom
            Section {
                if checker.isBackgroundRefreshEnabled {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Background Refresh Enabled")
                                .font(.subheadline)
                            Text("Your alarms will work reliably")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                } else {
                    NavigationLink {
                        BackgroundRefreshDebugView()
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Background Refresh Disabled")
                                    .font(.subheadline)
                                Text("Tap to enable for reliable alarms")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                        }
                    }
                }
            }
        }
    }
}

// EXAMPLE 3: Show as a prominent card
// Display as a card at the top when disabled:

struct AlarmListView: View {
    @ObservedObject var checker = BackgroundRefreshStatusChecker.shared
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Warning card
                if !checker.isBackgroundRefreshEnabled {
                    NavigationLink {
                        BackgroundRefreshDebugView()
                    } label: {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.title2)
                                .foregroundColor(.red)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Background Refresh Required")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                
                                Text("Tap to enable for reliable alarms")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.red.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.red.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.horizontal)
                    }
                }
                
                // Your alarm list...
            }
        }
    }
}

// EXAMPLE 4: Manual check button in toolbar
// Add a toolbar button to manually check status:

struct AlarmListView: View {
    @ObservedObject var checker = BackgroundRefreshStatusChecker.shared
    @State private var showDebugView = false
    
    var body: some View {
        List {
            // Your alarms...
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showDebugView = true
                } label: {
                    if checker.isBackgroundRefreshEnabled {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .sheet(isPresented: $showDebugView) {
            NavigationStack {
                BackgroundRefreshDebugView()
            }
        }
    }
}

// EXAMPLE 5: Onboarding/First Launch
// Show during first app launch to educate users:

struct OnboardingView: View {
    @ObservedObject var checker = BackgroundRefreshStatusChecker.shared
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(spacing: 30) {
            Text("Welcome to HaWake Alarm")
                .font(.largeTitle.bold())
            
            // ... other onboarding content ...
            
            // Background refresh step
            VStack(spacing: 15) {
                Image(systemName: checker.isBackgroundRefreshEnabled ? 
                      "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(checker.isBackgroundRefreshEnabled ? .green : .orange)
                
                Text("Enable Background Refresh")
                    .font(.title2.bold())
                
                Text("Required for alarms to work reliably when the app is closed")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                
                if !checker.isBackgroundRefreshEnabled {
                    Button("Enable Now") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            
            Button("Continue") {
                isPresented = false
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
}

*/
