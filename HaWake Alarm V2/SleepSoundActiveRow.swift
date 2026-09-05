
//
//  SleepSoundActiveRow.swift
//  HaWake Alarm V2
//
//  Displayed at the top of the alarm list while sleep sounds are playing or paused.
//  Styled to match AlarmRow — scales with biggerAlarmRows and respects wallpaper mode.
//

import SwiftUI
import Combine

struct SleepSoundActiveRow: View {
    let settings: DeviceSettings
    private let manager = SleepSoundManager.shared

    @Environment(\.colorScheme) private var colorScheme
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var tick = false  // forces time display refresh each second
    // Tapping the name area presents a LIVE version of the setup sheet, which
    // controls the running session directly (and hosts the station browser).
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

    private var timeRemainingString: String {
        _ = tick  // read tick so SwiftUI re-evaluates this property each second
        switch manager.state {
        case .paused:
            return "Paused"
        case .stopped:
            return ""
        case .playing:
            guard let remaining = manager.timeRemaining else {
                return "Playing"
            }
            let hours = Int(remaining) / 3600
            let minutes = (Int(remaining) % 3600) / 60
            let seconds = Int(remaining) % 60
            if hours > 0 {
                return String(format: "%d:%02d:%02d", hours, minutes, seconds)
            } else {
                return String(format: "%d:%02d", minutes, seconds)
            }
        }
    }

    /// Same value this row has always used (`toggleOnTint ?? .blue`), now read
    /// through the one accent funnel so the user's per-theme accent reaches it.
    private var themeAccentColor: Color {
        settings.appAccent(for: colorScheme)
    }

    private var statusColor: Color {
        manager.state == .paused ? .orange : themeAccentColor
    }

    var body: some View {
        VStack(spacing: 10 * scale) {
            // Top row: info + controls
            HStack(alignment: .center, spacing: 12) {
                // Left: info — flexible width, yields to controls on the right
                VStack(alignment: .leading, spacing: 4 * scale) {
                    // Tapping the name area opens a LIVE version of the setup
                    // sheet. Every control there acts on the running session
                    // instantly (sound/station swap, volume, timer), so the row
                    // no longer needs its own Menu or station browser.
                    Button {
                        showSetupSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(SleepSoundManager.displayName(for: manager.selectedSoundName))
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
                        Image(systemName: manager.state == .paused ? "pause.circle.fill" : "waveform")
                            .font(.system(size: 11 * scale))
                            .foregroundStyle(statusColor)
                        Text(timeRemainingString)
                            .font(.system(size: 13 * scale))
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .animation(.smooth, value: timeRemainingString)
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
                        // Same frosted-glass play/pause bubble as RadioActiveRow,
                        // so the two players match: accent glyph on translucent
                        // ultraThinMaterial. Sleep sounds are local files, so
                        // there is no connecting spinner (isConnecting: false).
                        RadioPlayCircle(
                            systemImage: manager.state == .playing ? "pause.fill" : "play.fill",
                            isConnecting: false,
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
                    get: { manager.volume },
                    set: { manager.setVolume($0) }
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
            tick.toggle()  // re-read timeRemainingString each second
        }
        .sheet(isPresented: $showSetupSheet) {
            SleepSoundSetupView(settings: settings, liveMode: true)
        }
    }
}
