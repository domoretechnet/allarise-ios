//
//  SleepTimerKidPickerView.swift
//  HaWake Alarm V2
//
//  First screen of Kids Sleep (al-2se): one big accent card per kid, plus an
//  add-kid card. Tapping a kid without a session pushes the create page;
//  tapping a kid mid-session opens the wake-point editor instead — one session
//  per kid, so "start" and "adjust" can share the same entry point.
//

import SwiftUI

struct SleepTimerKidPickerView: View {
    let settings: DeviceSettings
    /// Called when a create page starts a session; the presenter closes the cover.
    let onStart: (SleepTimerSession, SleepTimerStore.BedtimeAlarmChoice?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var store: SleepTimerStore { SleepTimerStore.shared }

    private var accentColor: Color {
        settings.appAccent(for: colorScheme)
    }

    @State private var path: [String] = []
    @State private var showingAddKid = false
    @State private var newKidName = ""
    @State private var editingSession: SleepTimerSession?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.kids, id: \.self) { kid in
                        kidCard(kid)
                    }
                    addKidCard
                }
                .padding(16)
            }
            .navigationTitle("Kids Sleep")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(for: String.self) { kid in
                SleepTimerCreateView(settings: settings, kidName: kid, onCreate: onStart)
            }
            .alert("Add Kid", isPresented: $showingAddKid) {
                TextField("First name", text: $newKidName)
                Button("Add") {
                    store.addKid(newKidName)
                    newKidName = ""
                }
                Button("Cancel", role: .cancel) { newKidName = "" }
            } message: {
                Text("The name becomes the Home Assistant sensor for this kid, so pick it once.")
            }
            .sheet(item: $editingSession) { session in
                SleepTimerEditView(
                    settings: settings,
                    session: session,
                    onSave: { SleepTimerStore.shared.updateSleepEnd(for: session.kidName, to: $0) },
                    onCancelTimer: { SleepTimerStore.shared.cancel(kidName: session.kidName) }
                )
            }
        }
    }

    private func kidCard(_ kid: String) -> some View {
        let session = store.session(for: kid)
        return Button {
            if let session {
                editingSession = session
            } else {
                path.append(kid)
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: session == nil ? "bed.double.fill" : "moon.zzz.fill")
                    .font(.title)
                Text(kid)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let session {
                    // Phase at render is enough here — the tracker card is the
                    // live view; this is a picker.
                    Text(SleepTimerLogic.phase(of: session, at: Date()).displayName)
                        .font(.caption.weight(.semibold))
                        .opacity(0.85)
                } else {
                    Text("Start sleep timer")
                        .font(.caption)
                        .opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 130)
            .background(accentColor, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                store.removeKid(kid)
            } label: {
                Label("Remove \(kid)", systemImage: "trash")
            }
        }
    }

    private var addKidCard: some View {
        Button {
            showingAddKid = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.title)
                Text("Add Kid")
                    .font(.title3.weight(.bold))
            }
            .foregroundStyle(accentColor)
            .frame(maxWidth: .infinity)
            .frame(height: 130)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            )
        }
        .buttonStyle(.plain)
    }
}
