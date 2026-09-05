//
//  BackgroundRefreshWarningView.swift
//  HaWake Alarm V2
//
//  Alarmy-style nagging view for background refresh settings
//

import SwiftUI
import Combine
import UserNotifications
import UIKit

struct BackgroundRefreshWarningView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingSettings = false

    /// Dark accent, pinned: this view paints its own black scrim and white text
    /// regardless of the ambient appearance, so resolving against a light scheme
    /// would tint the CTA for a background it never has. Same reasoning as
    /// `TermsUpdateView` in OnboardingView. The button was a literal `Color.blue`
    /// and so ignored a custom accent entirely (al-nl9).
    private var accent: Color { DeviceSettings.shared.appAccent(for: .dark) }

    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.8)
                .ignoresSafeArea()

            // Scrollable so nothing clips on shorter devices or larger Dynamic
            // Type — the "How to enable" instruction was being truncated with an
            // ellipsis, hiding the very setting name the user needs (al-kam).
            ScrollView {
            VStack(spacing: 30) {
                // Warning icon
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.yellow)
                
                // Title
                Text("Background Refresh Required")
                    .font(.title.bold())
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                
                // Explanation
                VStack(alignment: .leading, spacing: 15) {
                    WarningPointView(
                        icon: "bell.slash.fill",
                        text: "Your alarms may not ring if Background App Refresh is disabled"
                    )
                    
                    WarningPointView(
                        icon: "iphone.slash",
                        text: "The app needs to run in the background to ensure alarms work reliably"
                    )
                    
                    WarningPointView(
                        icon: "checkmark.circle.fill",
                        text: "Enable Background App Refresh to guarantee your alarms work"
                    )
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 15)
                        .fill(Color.white.opacity(0.1))
                )
                
                // Instructions
                VStack(spacing: 10) {
                    Text("How to enable:")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Text("Tap \"Open Settings\" below to go to Allarise's settings page, then enable \"Background App Refresh\"")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
                
                // Open Settings button
                Button(action: openSettings) {
                    HStack {
                        Image(systemName: "gear")
                        Text("Open Settings")
                    }
                    .font(.title3.bold())
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(accent)
                    .cornerRadius(15)
                }
                
                // Dismiss button (smaller, less prominent)
                Button(action: { dismiss() }) {
                    Text("I'll Do It Later")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.6))
                        .underline()
                }
            }
            .padding(30)
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

struct WarningPointView: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.yellow)
                .frame(width: 30)
            
            Text(text)
                .font(.body)
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Background Refresh Status Checker

class BackgroundRefreshStatusChecker: ObservableObject {
    @Published var isBackgroundRefreshEnabled = true
    @Published var showWarning = false
    @Published var statusDescription = ""
    
    static let shared = BackgroundRefreshStatusChecker()
    
    private init() {
        checkStatus()
        
        // Check status periodically
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkStatus()
        }
        
        // Also check when app becomes active
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(checkStatus),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }
    
    @objc func checkStatus() {
        DispatchQueue.main.async {
            let status = UIApplication.shared.backgroundRefreshStatus
            self.isBackgroundRefreshEnabled = (status == .available)
            
            // Set status description for debugging
            switch status {
            case .available:
                self.statusDescription = "Background Refresh: Available ✅"
            case .denied:
                self.statusDescription = "Background Refresh: Denied by User ❌"
            case .restricted:
                self.statusDescription = "Background Refresh: Restricted (Parental Controls) ❌"
            @unknown default:
                self.statusDescription = "Background Refresh: Unknown Status ⚠️"
            }
            
            print("📊 \(self.statusDescription)")
            
            // Show warning if disabled and user hasn't suppressed it. With
            // persistence Off, alarms are pure AlarmKit and BG refresh isn't
            // needed — same gate as checkBackgroundRefreshAndWarn.
            if !self.isBackgroundRefreshEnabled
                && !DeviceSettings.shared.suppressBackgroundRefreshWarning
                && DeviceSettings.shared.appPersistenceMode != .off {
                self.showWarning = true
            }
        }
    }
    
    func dismissWarning() {
        showWarning = false
        
        // Check again in 5 minutes
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            self?.checkStatus()
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Inline Warning Banner

struct BackgroundRefreshBanner: View {
    @ObservedObject var checker = BackgroundRefreshStatusChecker.shared
    @State private var showFullWarning = false
    let settings = DeviceSettings.shared
    
    var body: some View {
        Group {
            if !checker.isBackgroundRefreshEnabled
                && !settings.suppressBackgroundRefreshWarning
                && settings.appPersistenceMode != .off {
                Button(action: { showFullWarning = true }) {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Background Refresh Disabled")
                                .font(.subheadline.bold())
                                .foregroundColor(.white)
                            
                            Text("Tap to enable for reliable alarms")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.orange.opacity(0.9))
                    )
                    .padding(.horizontal)
                }
                .sheet(isPresented: $showFullWarning) {
                    BackgroundRefreshWarningView()
                }
            }
        }
    }
}

// MARK: - View Modifier for Easy Integration

struct BackgroundRefreshWarningModifier: ViewModifier {
    @ObservedObject var checker = BackgroundRefreshStatusChecker.shared
    
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $checker.showWarning) {
                BackgroundRefreshWarningView()
                    .onDisappear {
                        checker.dismissWarning()
                    }
            }
    }
}

extension View {
    func showBackgroundRefreshWarning() -> some View {
        modifier(BackgroundRefreshWarningModifier())
    }
}

// MARK: - Alarm Permission (Notifications) Warning

/// Tracks whether notification permission is DENIED. Local notifications are the primary
/// alarm-delivery mechanism, so when they're denied alarms won't ring reliably — we surface
/// a prominent banner so the user can re-enable them. Re-checks on app foreground (the only
/// time the status can change, since it's toggled in Settings).
@MainActor
final class AlarmPermissionStatusChecker: ObservableObject {
    /// Notification permission denied — the primary alarm delivery path.
    @Published var notificationsDenied = false
    /// AlarmKit (system alarm) permission denied — the reliable failsafe can't be scheduled.
    @Published var alarmKitDenied = false
    static let shared = AlarmPermissionStatusChecker()

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        // Only warn on explicit denial — .notDetermined is handled by onboarding, and
        // .provisional/.authorized are fine.
        notificationsDenied = (settings.authorizationStatus == .denied)
        // AlarmKit read-only state check (does not prompt).
        alarmKitDenied = AlarmKitScheduler.shared.isAuthorizationDenied
    }
}

/// Inline red banner shown on the alarm list when notifications are off. Tapping opens
/// the app's Settings page so the user can re-enable them.
struct AlarmPermissionBanner: View {
    @ObservedObject var checker = AlarmPermissionStatusChecker.shared

    var body: some View {
        Group {
            if checker.alarmKitDenied || checker.notificationsDenied {
                Button(action: openSettings) {
                    HStack(spacing: 12) {
                        Image(systemName: "bell.slash.fill")
                            .foregroundColor(.white)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Alarms Won't Ring")
                                .font(.subheadline.bold())
                                .foregroundColor(.white)

                            Text(message)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.red.opacity(0.9))
                    )
                    .padding(.horizontal)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Message adapts to which permission(s) are missing. AlarmKit is the reliable system
    /// alarm; notifications are the delivery path — either being off breaks alarms.
    private var message: String {
        if checker.alarmKitDenied && checker.notificationsDenied {
            return "Alarm and notification permissions are off — tap to enable them in Settings."
        } else if checker.alarmKitDenied {
            return "Allarise needs alarm permission to schedule alarms — tap to enable it in Settings."
        } else {
            return "Notifications are turned off — tap to enable them in Settings."
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
