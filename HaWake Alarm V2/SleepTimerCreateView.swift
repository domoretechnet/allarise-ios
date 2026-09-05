//
//  SleepTimerCreateView.swift
//  HaWake Alarm V2
//
//  Create sheet for the debug-only sleep timer (al-2se). Silent by design — no
//  sound, vibration, or notification controls anywhere; the phone only publishes
//  the schedule and Home Assistant drives the OK-to-wake light. Presented via
//  fullScreenCover by the caller.
//

import SwiftUI

struct SleepTimerCreateView: View {
    let settings: DeviceSettings
    /// The kid this session is for; stamped into the session and the HA topic.
    let kidName: String
    /// Second parameter: the optional "also ring a real app alarm at bed time"
    /// choice (al-5a94) — nil when the toggle is off.
    let onCreate: (SleepTimerSession, SleepTimerStore.BedtimeAlarmChoice?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var accentColor: Color {
        settings.appAccent(for: colorScheme)
    }

    // One row of quick picks; the +/- stepper moves in 5-minute jumps and the
    // timeline's bed-time dot drags in 1-minute steps for fine adjustment
    // (user decision 2026-08-21 — nine preset tiles was overkill).
    // Below 1 minute the stepper walks 1 min → 30 sec → Now (al-is5q), so the
    // countdown is held in seconds; 0 means "bed right now".
    private let presetMinutes = [5, 10, 15]
    private let stepSeconds = 5 * 60

    @State private var selectedSeconds = 15 * 60
    @State private var type: SleepTimerType
    @State private var sleepEnd: Date
    // Whether the user has hand-placed the wake point. Resets when the type flips
    // (each type has its own natural default).
    @State private var userDragged = false
    // Guards the sleepEnd .onChange so our own recomputes are not mistaken for a
    // user drag.
    @State private var programmaticChange = false
    // HA-side extra, remembered per kid across sessions (SleepTimerStore
    // options). The chosen value rides the session payload for HA to act on.
    @State private var busyLightAudio: Bool
    // Local bedtime alarm (al-5a94): rings a REAL app alarm at bed time on this
    // phone. Remembered per kid like the busy-light toggle; never published.
    // The sound options mirror the full alarm editor (per-alarm volume,
    // vibrate with the watch note, fade-in, wake-up radio) and are edited on
    // SleepTimerAlarmSoundView, presented as a sheet from the extras card.
    @State private var bedtimeAlarmEnabled: Bool
    @State private var bedtimeAlarmSoundID: String
    @State private var bedtimeAlarmVolume: Double?
    @State private var bedtimeAlarmVibrate: Bool?
    @State private var bedtimeAlarmFadeIn: Bool?
    @State private var bedtimeAlarmFadeInDuration: Int?
    @State private var bedtimeAlarmRadioStation: RadioStation?
    @State private var showBedtimeAlarmSound = false

    init(settings: DeviceSettings, kidName: String,
         onCreate: @escaping (SleepTimerSession, SleepTimerStore.BedtimeAlarmChoice?) -> Void) {
        self.settings = settings
        self.kidName = kidName
        self.onCreate = onCreate
        let now = Date()
        let bed = now.addingTimeInterval(15 * 60)
        let detected = SleepTimerLogic.detectedType(at: now)
        _type = State(initialValue: detected)
        _sleepEnd = State(initialValue: SleepTimerLogic.defaultSleepEnd(type: detected, bedTime: bed))
        let opts = SleepTimerStore.shared.options(for: kidName)
        _busyLightAudio = State(initialValue: opts.busyLightAudio)
        _bedtimeAlarmEnabled = State(initialValue: opts.bedtimeAlarmEnabled ?? false)
        _bedtimeAlarmSoundID = State(initialValue: opts.bedtimeAlarmSoundID ?? settings.defaultAlarmSound)
        _bedtimeAlarmVolume = State(initialValue: opts.bedtimeAlarmVolume)
        _bedtimeAlarmVibrate = State(initialValue: opts.bedtimeAlarmVibrate)
        _bedtimeAlarmFadeIn = State(initialValue: opts.bedtimeAlarmFadeIn)
        _bedtimeAlarmFadeInDuration = State(initialValue: opts.bedtimeAlarmFadeInDuration)
        // Prefer the live favorite (fresh URL/metadata), fall back to the
        // stored snapshot — same recipe as AlarmEditorView.
        if let stationID = opts.bedtimeAlarmRadioID, let stationURL = opts.bedtimeAlarmRadioURL {
            let favorite = RadioPlayerManager.shared.favorites.first { $0.id == stationID }
            _bedtimeAlarmRadioStation = State(initialValue: favorite ?? RadioStation(
                id: stationID,
                name: opts.bedtimeAlarmRadioName ?? "Radio Station",
                streamURL: stationURL,
                faviconURL: nil, country: "", tags: "", codec: "", bitrate: 0
            ))
        }
    }

    // Live bed time for display and defaulting. The session's authoritative bed
    // time is recomputed at tap (see startTimer) so an idle sheet cannot ship a
    // stale countdown.
    private var bedTime: Date {
        Date().addingTimeInterval(TimeInterval(selectedSeconds))
    }

    private var minimumSleepEnd: Date { bedTime.addingTimeInterval(30 * 60) }
    private var maximumSleepEnd: Date { bedTime.addingTimeInterval(14 * 60 * 60) }

    var body: some View {
        // No NavigationStack of its own: this page is pushed from the kid
        // picker's stack, and a nested stack would break the push.
        ScrollView {
                VStack(spacing: 16) {
                    typeSection
                    countdownPicker
                        .padding(.top, 16)
                    presetGrid
                    SleepTimerTimelineView(
                        sessionStart: Date(),
                        bedTime: bedTime,
                        sleepEnd: $sleepEnd,
                        minimumSleepEnd: minimumSleepEnd,
                        maximumSleepEnd: maximumSleepEnd,
                        accentColor: accentColor,
                        now: nil,
                        onBedTimeDrag: { newBed in
                            // The dot IS the countdown: bed time is always
                            // now + selectedSeconds, so the 1-minute drag just
                            // rewrites the count. Sub-minute values stay the
                            // stepper's job — the drag floors at 1 minute.
                            selectedSeconds = max(60,
                                                  60 * Int((newBed.timeIntervalSinceNow / 60).rounded()))
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 20)

                    extrasSection
                        .padding(.top, 4)
                }
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .safeAreaBar(edge: .bottom) {
                Button {
                    startTimer()
                } label: {
                    Text("Start Sleep Timer")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(accentColor, in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .buttonStyle(.plain)
                .background(.bar)
            }
            .navigationTitle(kidName.isEmpty ? "Sleep Timer" : "\(kidName)'s Sleep")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: type) { _, newType in
                userDragged = false
                setSleepEndProgrammatically(SleepTimerLogic.defaultSleepEnd(type: newType, bedTime: bedTime))
            }
            .onChange(of: selectedSeconds) { oldValue, newValue in
                let delta = TimeInterval(newValue - oldValue)
                if !userDragged {
                    setSleepEndProgrammatically(SleepTimerLogic.defaultSleepEnd(type: type, bedTime: bedTime))
                } else if type == .nap {
                    // Nap wake tracks the bed time, so preserve the user's chosen
                    // duration by sliding it along with the countdown.
                    setSleepEndProgrammatically(sleepEnd.addingTimeInterval(delta))
                }
                // Bedtime wake is an absolute clock time (next 6 AM), so a
                // countdown change leaves a hand-dragged value untouched.
            }
            .onChange(of: sleepEnd) { _, _ in
                if programmaticChange {
                    programmaticChange = false
                } else {
                    userDragged = true
                }
            }
    }

    private var countdownPicker: some View {
        VStack(spacing: 4) {
            HStack(spacing: 16) {
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        // Snap DOWN the 5-minute ladder (a dragged 7 min goes
                        // to 5, not 2), then 1 min, 30 sec, Now.
                        if selectedSeconds > stepSeconds {
                            selectedSeconds = ((selectedSeconds - 1) / stepSeconds) * stepSeconds
                        } else if selectedSeconds > 60 {
                            selectedSeconds = 60
                        } else if selectedSeconds > 30 {
                            selectedSeconds = 30
                        } else {
                            selectedSeconds = 0
                        }
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title)
                        .foregroundStyle(selectedSeconds > 0 ? accentColor : .gray.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(selectedSeconds <= 0)

                Text(countdownString)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .animation(.smooth, value: selectedSeconds)

                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        // Mirror of minus: climb the sub-minute rungs, then
                        // snap UP the 5-minute ladder (1 min goes to 5, not 6).
                        if selectedSeconds < 30 {
                            selectedSeconds = 30
                        } else if selectedSeconds < 60 {
                            selectedSeconds = 60
                        } else {
                            selectedSeconds = ((selectedSeconds / stepSeconds) + 1) * stepSeconds
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title)
                        .foregroundStyle(accentColor)
                }
                .buttonStyle(.plain)
            }
            Text(selectedSeconds == 0 ? "Bed right now" : "Bed at \(shortTime(bedTime))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var presetGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(presetMinutes, id: \.self) { minutes in
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        selectedSeconds = minutes * 60
                    }
                } label: {
                    Text("\(minutes) min")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(selectedSeconds == minutes * 60 ? .white : accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            selectedSeconds == minutes * 60
                            ? AnyShapeStyle(accentColor)
                            : AnyShapeStyle(.ultraThinMaterial)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private var typeSection: some View {
        VStack(spacing: 8) {
            // Same accent-filled idiom as the preset grid, so the type choice
            // reads as a first-class control rather than a stock segmented bar.
            HStack(spacing: 8) {
                ForEach(SleepTimerType.allCases, id: \.self) { t in
                    Button {
                        withAnimation(.smooth(duration: 0.2)) {
                            type = t
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: t == .nap ? "sun.haze.fill" : "moon.stars.fill")
                                .font(.subheadline.weight(.semibold))
                            Text(t.displayName)
                                .font(.body.weight(.semibold))
                        }
                        .foregroundStyle(type == t ? .white : accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            type == t
                            ? AnyShapeStyle(accentColor)
                            : AnyShapeStyle(.ultraThinMaterial)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            // (Consequence caption removed by user request 2026-08-13 — the
            // timeline's live wake label carries the same information.)
        }
        .padding(.horizontal, 16)
    }

    private var countdownString: String {
        if selectedSeconds == 0 { return "Now" }
        if selectedSeconds < 60 { return "\(selectedSeconds) sec" }
        let totalMinutes = selectedSeconds / 60
        if totalMinutes >= 60 {
            let hours = totalMinutes / 60
            let mins = totalMinutes % 60
            return mins == 0 ? "\(hours) hr" : "\(hours) hr \(mins) min"
        }
        return "\(totalMinutes) min"
    }

    private func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// The two HA-side extras, in the same rowed-card idiom as Quick Alarm's
    /// sound/volume block. What each does lives in HA automations; the app
    /// only carries the flags.
    private var extrasSection: some View {
        // (The "Google Home Timer" sibling toggle was removed 2026-08-14 —
        // native Google timers cannot be set programmatically, verified by
        // the HA-side probe.)
        VStack(spacing: 0) {
            // Gates only the tone — the light's 30 s red flash at bed time
            // always happens (HA-side semantics, confirmed 2026-08-14).
            Toggle(isOn: $busyLightAudio) {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.title3)
                        .foregroundStyle(accentColor)
                        .frame(width: 28)
                    Text("Busy Light Tone at Bedtime")
                        .font(.body.weight(.semibold))
                }
            }
            .tint(accentColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)

            Divider()
                .padding(.leading, 56)

            // Local bedtime alarm (al-5a94): a real app alarm rings on THIS
            // phone when the countdown ends — tap to dismiss, no snooze, no
            // missions, invisible to HA (the kids_sleep tree is HA's view).
            Toggle(isOn: $bedtimeAlarmEnabled.animation()) {
                HStack(spacing: 12) {
                    Image(systemName: "alarm.fill")
                        .font(.title3)
                        .foregroundStyle(accentColor)
                        .frame(width: 28)
                    Text("Alarm on This Phone at Bedtime")
                        .font(.body.weight(.semibold))
                }
            }
            .tint(accentColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)

            if bedtimeAlarmEnabled {
                Divider()
                    .padding(.leading, 56)

                // Summary row → the full sound screen (same options as a real
                // alarm editor: tones, custom tones, radio, volume, vibrate,
                // fade-in). A second screen because the full section needs a
                // Form root and its own pop-out anchors.
                Button {
                    showBedtimeAlarmSound = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: bedtimeAlarmRadioStation != nil ? "radio.fill" : "music.note")
                            .font(.title3)
                            .foregroundStyle(accentColor)
                            .frame(width: 28)
                        Text("Sound")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(bedtimeAlarmSoundSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .sheet(isPresented: $showBedtimeAlarmSound) {
            SleepTimerAlarmSoundView(
                settings: settings,
                soundID: $bedtimeAlarmSoundID,
                customVolume: $bedtimeAlarmVolume,
                customVibrate: $bedtimeAlarmVibrate,
                customFadeIn: $bedtimeAlarmFadeIn,
                customFadeInDuration: $bedtimeAlarmFadeInDuration,
                radioStation: $bedtimeAlarmRadioStation
            )
            .appAppearanceTheme(settings)
        }
    }

    /// What the sound row's trailing text shows: the radio station when one is
    /// chosen (radio wins at ring time), else the tone's display name.
    private var bedtimeAlarmSoundSummary: String {
        if let station = bedtimeAlarmRadioStation { return station.name }
        return AlarmSoundManager.shared.getSound(id: bedtimeAlarmSoundID)?.displayName ?? bedtimeAlarmSoundID
    }

    private func setSleepEndProgrammatically(_ newEnd: Date) {
        programmaticChange = true
        sleepEnd = newEnd
    }

    private func startTimer() {
        // Recompute bed time from Date() at tap: the sheet may have sat open, and
        // the schedule HA receives must count from now, not from when it opened.
        // "Now" (0 s) means bed = this very moment: HA sees a bed_time that has
        // already arrived and runs the busy-light ladder immediately, and the
        // optional phone alarm rings immediately via the exact-fire-time path.
        let bed = Date().addingTimeInterval(TimeInterval(selectedSeconds))
        // The stored wake point aged along with the sheet: an untouched default
        // is recomputed against the fresh bed time (otherwise an idle sheet
        // silently shortens the nap); a hand-dragged wake keeps its absolute
        // time, clamped clear of the ringing window.
        let end = userDragged
            ? max(sleepEnd, bed.addingTimeInterval(30 * 60))
            : SleepTimerLogic.defaultSleepEnd(type: type, bedTime: bed)
        // Remember the toggle choices as this kid's defaults for next time.
        SleepTimerStore.shared.setOptions(
            SleepTimerStore.KidOptions(
                busyLightAudio: busyLightAudio,
                bedtimeAlarmEnabled: bedtimeAlarmEnabled,
                bedtimeAlarmSoundID: bedtimeAlarmSoundID,
                bedtimeAlarmVolume: bedtimeAlarmVolume,
                bedtimeAlarmVibrate: bedtimeAlarmVibrate,
                bedtimeAlarmFadeIn: bedtimeAlarmFadeIn,
                bedtimeAlarmFadeInDuration: bedtimeAlarmFadeInDuration,
                bedtimeAlarmRadioID: bedtimeAlarmRadioStation?.id,
                bedtimeAlarmRadioName: bedtimeAlarmRadioStation?.name,
                bedtimeAlarmRadioURL: bedtimeAlarmRadioStation?.streamURL
            ),
            for: kidName
        )
        let session = SleepTimerSession(
            id: UUID(),
            type: type,
            createdAt: Date(),
            bedTime: bed,
            sleepEnd: end,
            kidName: kidName,
            busyLightAudioEnabled: busyLightAudio
        )
        let alarmChoice = bedtimeAlarmEnabled
            ? SleepTimerStore.BedtimeAlarmChoice(
                soundID: bedtimeAlarmSoundID,
                volume: bedtimeAlarmVolume,
                vibrate: bedtimeAlarmVibrate,
                fadeIn: bedtimeAlarmFadeIn,
                fadeInDuration: bedtimeAlarmFadeInDuration,
                radioStation: bedtimeAlarmRadioStation
              )
            : nil
        onCreate(session, alarmChoice)
        dismiss()
    }
}
