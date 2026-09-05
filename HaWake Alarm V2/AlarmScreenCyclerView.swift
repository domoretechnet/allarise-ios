//
//  AlarmScreenCyclerView.swift
//  HaWake Alarm V2
//
//  DEBUG-only visual cycler through the alarm/mission screens, opened from the
//  floating home-screen bubble. Steps through the landing screen and each
//  mission full-screen, with an inline "Mission Wallpaper" toggle so the
//  wallpaper-on/off look can be compared without leaving the screen.
//

#if DEBUG
import SwiftUI

struct AlarmScreenCyclerView: View {
    @Bindable var settings: DeviceSettings
    @Environment(\.dismiss) private var dismiss

    @State private var index = 0

    private struct Screen {
        let label: String
        let type: MissionType
        let startInMission: Bool
    }

    private let screens: [Screen] = [
        Screen(label: "Landing", type: .none, startInMission: false),
        Screen(label: "Math", type: .math, startInMission: true),
        Screen(label: "Shake", type: .shake, startInMission: true),
        Screen(label: "Marble", type: .balanceBall, startInMission: true),
        Screen(label: "Blocks", type: .blockDrop, startInMission: true),
        Screen(label: "Meteor", type: .meteor, startInMission: true),
        Screen(label: "Home Assistant", type: .homeAssistant, startInMission: true),
    ]

    var body: some View {
        ZStack(alignment: .top) {
            let screen = screens[index]
            ActiveAlarmView(
                alarm: Alarm(label: "Wake Up", mission: Mission(type: screen.type)),
                settings: settings,
                onDismiss: { dismiss() },
                onSnooze: {},
                debugStartInMission: screen.startInMission
            )
            // Rebuild the alarm view when switching screens so phase/mission reset.
            .id(index)

            controlBar
        }
        .statusBarHidden(true)
    }

    private var controlBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { step(-1) } label: {
                    Image(systemName: "chevron.left.circle.fill").font(.title2)
                }
                Text(screens[index].label)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(minWidth: 130)
                Button { step(1) } label: {
                    Image(systemName: "chevron.right.circle.fill").font(.title2)
                }

                Divider().frame(height: 20)

                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2)
                }
            }
            .foregroundStyle(.white)

            Toggle(isOn: Binding(
                get: { settings.debugMissionWallpaperEnabled },
                set: { settings.debugMissionWallpaperEnabled = $0 }
            )) {
                Text("Mission Wallpaper").font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)
            .tint(settings.appAccent(for: .dark))
            .frame(maxWidth: 230)
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .padding(.top, 8)
    }

    private func step(_ delta: Int) {
        index = (index + delta + screens.count) % screens.count
    }
}
#endif
