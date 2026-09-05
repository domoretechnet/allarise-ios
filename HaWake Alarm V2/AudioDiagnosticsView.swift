//
//  AudioDiagnosticsView.swift
//  HaWake Alarm V2
//
//  Debug-only live view of the AudioDiagnostics snapshot. Renders the
//  output of `AudioDiagnostics.captureState(label:)` in a monospaced
//  ScrollView, with optional auto-refresh so the state can be watched in
//  real time as audio subsystems transition.
//
//  The whole file is compiled out of Release builds, so nothing here ships
//  to TestFlight or the App Store.
//

#if DEBUG
import SwiftUI

struct AudioDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: String = ""
    @State private var autoRefresh = false
    @State private var refreshTimer: Timer?
    @State private var lastCapturedAt: Date = Date()

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(snapshot)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Audio State")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            refresh()
                        } label: {
                            Label("Refresh Now", systemImage: "arrow.clockwise")
                        }
                        Toggle(isOn: $autoRefresh) {
                            Label("Auto-Refresh (1s)", systemImage: "timer")
                        }
                        Divider()
                        Button {
                            _ = AudioDiagnostics.printState(label: "live-monitor")
                        } label: {
                            Label("Log Snapshot", systemImage: "text.append")
                        }
                        ShareLink(item: snapshot) {
                            Label("Share / Copy", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Image(systemName: autoRefresh ? "dot.radiowaves.left.and.right" : "clock")
                        .foregroundStyle(autoRefresh ? .green : .secondary)
                    Text(autoRefresh
                         ? "Auto-refreshing every 1s"
                         : "Captured \(timeAgoDescription(lastCapturedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
        .onAppear { refresh() }
        .onChange(of: autoRefresh) { _, enabled in
            if enabled { startAutoRefresh() } else { stopAutoRefresh() }
        }
        .onDisappear { stopAutoRefresh() }
    }

    // MARK: - State capture

    private func refresh() {
        snapshot = AudioDiagnostics.captureState(label: "live-monitor")
        lastCapturedAt = Date()
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in refresh() }
        }
        if let timer = refreshTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Helpers

    private func timeAgoDescription(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 1 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m \(seconds % 60)s ago"
    }
}
#endif
