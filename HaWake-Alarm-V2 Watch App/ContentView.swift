//
//  ContentView.swift
//  HaWake-Alarm-V2 Watch App
//
//  Minimal watch face: shows alarm label + Stop button while vibrating,
//  idle state otherwise.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var hapticManager: WatchHapticManager

    var body: some View {
        if hapticManager.isVibrating {
            alarmActiveView
        } else {
            idleView
        }
    }

    // MARK: - Alarm Active

    private var alarmActiveView: some View {
        VStack(spacing: 12) {
            Image(systemName: "alarm.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)

            Text(hapticManager.alarmLabel)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Button {
                hapticManager.stopVibration()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.body.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding()
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: 8) {
            Image(systemName: "applewatch.radiowaves.left.and.right")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("HaWake")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Watch vibration ready")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
        .environmentObject(WatchHapticManager.shared)
}
