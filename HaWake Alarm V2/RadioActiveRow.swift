//
//  RadioActiveRow.swift
//  HaWake Alarm V2
//
//  Displayed in the alarm list while a radio station is playing or paused.
//  Mirrors SleepSoundActiveRow's styling — scales with biggerAlarmRows and
//  respects wallpaper/glass mode.
//

import SwiftUI
import Combine

struct RadioActiveRow: View {
    let settings: DeviceSettings
    private let manager = RadioPlayerManager.shared

    @Environment(\.colorScheme) private var colorScheme
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var tick = false  // refreshes the sleep-timer countdown

    // Tapping the name area presents the LIVE setup sheet (same as
    // SleepSoundActiveRow), which hosts all switching and the station browser.
    @State private var showSetupSheet = false

    private var scale: CGFloat {
        settings.biggerAlarmRows ? 1.2 : 1.0
    }

    private var useDarkSettings: Bool {
        colorScheme == .dark
    }

    private var homeGlassVariant: Glass {
        guard settings.homeWallpaperEnabled else { return .identity }
        let variant = useDarkSettings ? settings.homeDarkGlassVariant : settings.homeGlassVariant
        switch variant {
        case 1: return .clear
        case 2:
            let r = useDarkSettings ? settings.homeDarkGlassTintRed : settings.homeGlassTintRed
            let g = useDarkSettings ? settings.homeDarkGlassTintGreen : settings.homeGlassTintGreen
            let b = useDarkSettings ? settings.homeDarkGlassTintBlue : settings.homeGlassTintBlue
            let opacity = useDarkSettings ? settings.homeDarkGlassTintOpacity : settings.homeGlassTintOpacity
            return .regular.tint(Color(red: r, green: g, blue: b).opacity(opacity))
        default: return .regular
        }
    }

    private var homeClearDimming: Double {
        let variant = useDarkSettings ? settings.homeDarkGlassVariant : settings.homeGlassVariant
        guard variant == 1 else { return 0 }
        return useDarkSettings ? settings.homeDarkGlassClearDimming : settings.homeGlassClearDimming
    }

    /// Same value this row has always used (`toggleOnTint ?? .blue`), now read
    /// through the one accent funnel so the user's per-theme accent reaches it.
    private var themeAccentColor: Color {
        settings.appAccent(for: colorScheme)
    }

    private var statusColor: Color {
        manager.state == .paused ? .orange : themeAccentColor
    }

    private var statusText: String {
        _ = tick  // re-evaluate each second while a sleep timer runs
        if manager.state == .paused { return "Paused" }
        guard let end = manager.sleepTimerEnd else { return "Live" }
        let remaining = max(0, Int(end.timeIntervalSinceNow))
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        let seconds = remaining % 60
        let countdown = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
        return "Live · \(countdown)"
    }

    var body: some View {
        VStack(spacing: 10 * scale) {
            // Top row: info + controls
            HStack(alignment: .center, spacing: 12) {
                // Left: station info — tapping opens the LIVE setup sheet,
                // which controls the running session directly (station/sound
                // swap, volume, timer) and hosts the station browser.
                VStack(alignment: .leading, spacing: 4 * scale) {
                    Button {
                        showSetupSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(manager.currentStation?.name ?? "Radio")
                                .font(.system(size: 22 * scale, weight: .semibold))
                                .lineLimit(2)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 11 * scale, weight: .medium))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 4) {
                        Image(systemName: manager.state == .paused ? "pause.circle.fill" : "dot.radiowaves.left.and.right")
                            .font(.system(size: 11 * scale))
                            .foregroundStyle(statusColor)
                        Text(statusText)
                            .font(.system(size: 13 * scale))
                            .foregroundStyle(.secondary)
                    }
                }

                // Right: Pause/Resume — fixed size so it never gets squeezed
                HStack(spacing: 12 * scale) {
                    Button {
                        withAnimation(.smooth(duration: 0.2)) {
                            if manager.state == .playing {
                                manager.pause()
                            } else {
                                manager.resume()
                            }
                        }
                    } label: {
                        RadioPlayCircle(
                            systemImage: manager.state == .playing ? "pause.fill" : "play.fill",
                            isConnecting: manager.isConnecting,
                            diameter: 36 * scale,
                            fill: .material(themeAccentColor)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .fixedSize()
            }

            // Bottom: full-width volume slider
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(manager.volume) },
                    set: { manager.setVolume(Float($0)) }
                ), in: 0.0...1.0)
                .tint(themeAccentColor)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 18 * scale)
        .padding(.leading, 16 * scale)
        .padding(.trailing, 12 * scale)
        .background {
            if !settings.homeWallpaperEnabled {
                RoundedRectangle(cornerRadius: 16)
                    .fill(themeAccentColor.opacity(0.07))
                    .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
            } else if homeClearDimming > 0 {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(homeClearDimming))
            }
        }
        .glassEffect(homeGlassVariant, in: .rect(cornerRadius: 16))
        .overlay {
            if settings.homeWallpaperEnabled {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.4), lineWidth: 0.5)
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(themeAccentColor.opacity(0.25), lineWidth: 1)
            }
        }
        .onReceive(timer) { _ in
            tick.toggle()
        }
        .sheet(isPresented: $showSetupSheet) {
            SleepSoundSetupView(settings: settings, liveMode: true)
        }
    }
}
