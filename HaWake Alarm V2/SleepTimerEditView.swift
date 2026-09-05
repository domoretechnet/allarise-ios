//
//  SleepTimerEditView.swift
//  HaWake Alarm V2
//
//  Edit sheet for the running sleep timer (al-2se). Only the wake point moves —
//  the bed-time half is immutable once the countdown is running, so the elapsed
//  span renders locked. Silent by design: no sound/vibration/notification UI.
//  Presented as a sheet by the caller.
//

import SwiftUI

struct SleepTimerEditView: View {
    let settings: DeviceSettings
    let session: SleepTimerSession
    let onSave: (Date) -> Void          // new sleepEnd
    let onCancelTimer: () -> Void       // user kills the session

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var sleepEnd: Date

    init(settings: DeviceSettings,
         session: SleepTimerSession,
         onSave: @escaping (Date) -> Void,
         onCancelTimer: @escaping () -> Void) {
        self.settings = settings
        self.session = session
        self.onSave = onSave
        self.onCancelTimer = onCancelTimer
        _sleepEnd = State(initialValue: session.sleepEnd)
    }

    private var accentColor: Color {
        settings.appAccent(for: colorScheme)
    }

    private var maximumSleepEnd: Date {
        session.bedTime.addingTimeInterval(14 * 60 * 60)
    }

    // Live view of the session with the pending wake edit applied, so the phase
    // line and timeline reflect what Save would persist.
    private func editedSession() -> SleepTimerSession {
        var s = session
        s.sleepEnd = sleepEnd
        return s
    }

    private func minimumSleepEnd(now: Date) -> Date {
        max(session.bedTime.addingTimeInterval(30 * 60), ceilToNextFive(now))
    }

    var body: some View {
        NavigationStack {
            // Periodic tick keeps the phase and the locked elapsed span current
            // while the sheet stays open.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ScrollView {
                    VStack(spacing: 16) {
                        phaseHeader(now: context.date)

                        SleepTimerTimelineView(
                            sessionStart: session.createdAt,
                            bedTime: session.bedTime,
                            sleepEnd: $sleepEnd,
                            minimumSleepEnd: minimumSleepEnd(now: context.date),
                            maximumSleepEnd: maximumSleepEnd,
                            accentColor: accentColor,
                            now: context.date
                        )
                        .padding(.horizontal, 16)

                        Button(role: .destructive) {
                            onCancelTimer()
                            dismiss()
                        } label: {
                            Text("Cancel Sleep Timer")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
            }
            .safeAreaBar(edge: .bottom) {
                Button {
                    onSave(sleepEnd)
                    dismiss()
                } label: {
                    Text("Save")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(accentColor, in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .buttonStyle(.plain)
                .background(.bar)
            }
            .navigationTitle("Edit Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func phaseHeader(now: Date) -> some View {
        let phase = SleepTimerLogic.phase(of: editedSession(), at: now)
        return HStack(spacing: 10) {
            Image(systemName: symbol(for: phase))
                .font(.title2)
                .foregroundStyle(accentColor)
                .contentTransition(.symbolEffect(.replace))
            Text(phase.displayName)
                .font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func symbol(for phase: SleepTimerPhase) -> String {
        switch phase {
        case .beforeBed: return "moon.zzz.fill"
        case .ringing: return "bell.fill"
        case .sleeping1, .sleeping2, .sleeping3, .sleeping4: return "moon.stars.fill"
        case .off: return "sun.max.fill"
        }
    }

    private func ceilToNextFive(_ date: Date) -> Date {
        let step: TimeInterval = 5 * 60
        let t = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / step).rounded(.up) * step)
    }
}
