//
//  NWSAlertsSettingsView.swift
//  Allarise Alarm V2
//
//  Settings page for NWS Weather Alert monitoring.
//  HIGHLY EXPERIMENTAL
//

import SwiftUI
import SafariServices

struct NWSAlertsSettingsView: View {
    @Bindable var settings: DeviceSettings
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { settings.appAccent(for: colorScheme) }

    @State private var editingLocation: NWSMonitoredLocation?
    @State private var showAddLocation = false
    @State private var locationCountBeforeAdd = 0
    @State private var navigateToLocationID: UUID?
    @State private var showPersistenceRequiredAlert = false
    @State private var showTermsSheet = false
    @State private var termsURL = AppLinks.terms

    var body: some View {
        List {
            experimentalBanner

            locationsSection

            if !settings.nwsMonitoredLocations.isEmpty {
                statusSection
            }

            debugSection
        }
        .navigationTitle("NWS Weather Alerts")
        .alert("App Persistence Required", isPresented: $showPersistenceRequiredAlert) {
            Button("Enable") {
                settings.appPersistenceMode = .on
                Task.detached(priority: .utility) {
                    await BackgroundAudioKeepAlive.shared.startAsync()
                    await MainActor.run {
                        BackgroundAudioKeepAlive.shared.startHealthCheck()
                        settings.nwsDisclaimerAgreed = true
                        settings.nwsAlertsEnabled = true
                        NWSAlertService.shared.start()
                        if settings.nwsMonitoredLocations.isEmpty {
                            locationCountBeforeAdd = 0
                            showAddLocation = true
                        }
                    }
                }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("NWS Weather Alerts requires App Persistence to be enabled. Would you like to enable it now?")
        }
        .navigationDestination(item: $navigateToLocationID) { id in
            NWSLocationAlertSettingsView(settings: settings, locationID: id)
        }
        .sheet(isPresented: $showAddLocation, onDismiss: {
            if settings.nwsMonitoredLocations.count > locationCountBeforeAdd,
               let newLocation = settings.nwsMonitoredLocations.last {
                navigateToLocationID = newLocation.id
            }
        }) {
            NavigationStack {
                NWSLocationEditorView(settings: settings, existingLocation: nil)
            }
        }
        .sheet(item: $editingLocation) { location in
            NavigationStack {
                NWSLocationEditorView(settings: settings, existingLocation: location)
            }
        }
        .sheet(isPresented: $showTermsSheet) {
            SafariView(url: termsURL)
        }
    }

    // MARK: - Experimental Banner

    private var experimentalBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text("Notice & Disclaimer")
                        .font(.subheadline.weight(.bold))
                }

                Spacer().frame(height: 8)

                Text("NWS Weather Alerts is a beta feature — it may change, be unreliable, or behave unexpectedly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer().frame(height: 14)

                VStack(alignment: .leading, spacing: 8) {
                    disclaimerBullet(icon: "info.circle", text: "Provided as-is via the NWS public API — no guarantees of accuracy, timeliness, or delivery.")
                    disclaimerBullet(icon: "exclamationmark.triangle", text: "Must not be your sole source of emergency weather information. Always rely on WEA, NOAA Weather Radio, and official emergency systems.")
                    disclaimerBullet(icon: "antenna.radiowaves.left.and.right.slash", text: "Alerts may be delayed, missed, or incorrect due to connectivity, app state, or API availability.")
                    disclaimerBullet(icon: "hand.raised", text: "Allarise is not liable for any harm resulting from missed or incorrect alerts.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            }
            .padding(.vertical, 4)

            Toggle(isOn: Binding(
                get: { settings.nwsDisclaimerAgreed },
                set: { agreed in
                    if agreed && !settings.backgroundKeepAliveEnabled {
                        showPersistenceRequiredAlert = true
                        return
                    }
                    settings.nwsDisclaimerAgreed = agreed
                    settings.nwsAlertsEnabled = agreed
                    if agreed {
                        NWSAlertService.shared.start()
                        if settings.nwsMonitoredLocations.isEmpty {
                            locationCountBeforeAdd = 0
                            showAddLocation = true
                        }
                    } else {
                        NWSAlertService.shared.stop()
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agree & Enable")
                        .font(.subheadline.weight(.semibold))
                    Text("I have read and agree to the notice above and [app terms](\(AppLinks.termsString)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .tint(accent)
                        .environment(\.openURL, OpenURLAction { url in
                            termsURL = url
                            showTermsSheet = true
                            return .handled
                        })
                }
            }
            .tint(.green)
        }
    }

    private func disclaimerBullet(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Locations

    private var locationsSection: some View {
        Section {
            ForEach(settings.nwsMonitoredLocations) { location in
                NavigationLink {
                    NWSLocationAlertSettingsView(settings: settings, locationID: location.id)
                } label: {
                    locationRow(location)
                }
            }
            .onDelete(perform: deleteLocations)

            Button {
                locationCountBeforeAdd = settings.nwsMonitoredLocations.count
                showAddLocation = true
            } label: {
                Label("Add Location", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Monitored Locations")
        } footer: {
            Text("Each location is polled every 30 seconds for active NWS alerts. Tap a location to configure which alert types to monitor.")
        }
    }

    private func locationRow(_ location: NWSMonitoredLocation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: location.useCurrentLocation ? "location.fill" : "mappin.circle.fill")
                .font(.title3)
                .foregroundStyle(location.useCurrentLocation ? accent : .red)

            VStack(alignment: .leading, spacing: 2) {
                Text(location.name)
                    .font(.body)
                if location.useCurrentLocation {
                    Text("Using device GPS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(format: "%.4f, %.4f", location.latitude, location.longitude))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                let enabledCount = location.categorySettings.values.filter(\.enabled).count
                Text("\(enabledCount) alert types enabled")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                withAnimation {
                    var locs = settings.nwsMonitoredLocations
                    locs.removeAll { $0.id == location.id }
                    settings.nwsMonitoredLocations = locs
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }

            Button {
                editingLocation = location
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(accent)
        }
    }

    private func deleteLocations(at offsets: IndexSet) {
        var locs = settings.nwsMonitoredLocations
        locs.remove(atOffsets: offsets)
        settings.nwsMonitoredLocations = locs
    }

    // MARK: - Status

    private var statusSection: some View {
        Section("Status") {
            let service = NWSAlertService.shared
            HStack {
                Text("Polling")
                Spacer()
                Text(service.isPolling ? "Active" : "Stopped")
                    .foregroundStyle(service.isPolling ? .green : .secondary)
            }

            ForEach(settings.nwsMonitoredLocations) { location in
                if let lastPoll = service.lastPollTimes[location.id] {
                    HStack {
                        Text(location.name)
                            .font(.subheadline)
                        Spacer()
                        Text(lastPoll, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = service.lastErrors[location.id] {
                    HStack {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: - Debug

    private var debugSection: some View {
        Section("Advanced") {
            Button("Clear Seen Alerts") {
                NWSAlertService.shared.clearSeenAlerts()
            }
        }
    }

}

// MARK: - Per-Location Alert Type Settings

struct NWSLocationAlertSettingsView: View {
    @Bindable var settings: DeviceSettings
    let locationID: UUID

    @State private var selectedCategory: NWSAlertCategory?

    private var location: NWSMonitoredLocation? {
        settings.nwsMonitoredLocations.first { $0.id == locationID }
    }

    var body: some View {
        List {
            if let location {
                warningsSection(location)
                watchesSection(location)
            }
        }
        .navigationTitle(location?.name ?? "Alert Settings")
        .navigationDestination(item: $selectedCategory) { category in
            NWSCategoryDetailView(settings: settings, locationID: locationID, category: category)
        }
    }

    // MARK: - Category Sections

    private func warningsSection(_ location: NWSMonitoredLocation) -> some View {
        Section {
            ForEach(NWSAlertCategory.allCases.filter(\.isWarning)) { category in
                categoryRow(category, location: location)
            }
        } header: {
            Text("Warnings")
        } footer: {
            let enabledCount = NWSAlertCategory.allCases.filter(\.isWarning)
                .filter { location.settings(for: $0).enabled }.count
            if enabledCount == 0 {
                Text("No warning types are enabled. Toggle a type on or tap it to configure.")
            }
        }
    }

    private func watchesSection(_ location: NWSMonitoredLocation) -> some View {
        Section {
            ForEach(NWSAlertCategory.allCases.filter { !$0.isWarning }) { category in
                categoryRow(category, location: location)
            }
        } header: {
            Text("Watches")
        } footer: {
            let enabledCount = NWSAlertCategory.allCases.filter { !$0.isWarning }
                .filter { location.settings(for: $0).enabled }.count
            if enabledCount == 0 {
                Text("No watch types are enabled. Toggle a type on or tap it to configure.")
            }
        }
    }

    private func categoryRow(_ category: NWSAlertCategory, location: NWSMonitoredLocation) -> some View {
        NavigationLink {
            NWSCategoryDetailView(settings: settings, locationID: locationID, category: category)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: category.sfSymbol)
                    .foregroundStyle(category.color)
                    .frame(width: 24)
                Text(category.rawValue)
                    .font(.subheadline)
                Spacer()
                Toggle("", isOn: enabledBinding(for: category))
                    .labelsHidden()
                    .tint(.green)
            }
        }
    }

    // MARK: - Bindings & Helpers

    private func enabledBinding(for category: NWSAlertCategory) -> Binding<Bool> {
        Binding(
            get: { location?.settings(for: category).enabled ?? false },
            set: { newValue in
                var locs = settings.nwsMonitoredLocations
                guard let idx = locs.firstIndex(where: { $0.id == locationID }) else { return }
                var cat = locs[idx].settings(for: category)
                cat.enabled = newValue
                locs[idx].categorySettings[category.rawValue] = cat
                settings.nwsMonitoredLocations = locs
            }
        )
    }

}

// MARK: - Category Detail Settings

struct NWSCategoryDetailView: View {
    @Bindable var settings: DeviceSettings
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { settings.appAccent(for: colorScheme) }
    let locationID: UUID
    let category: NWSAlertCategory

    @State private var isTesting = false

    private var catSettings: NWSAlertCategorySettings {
        guard let location = settings.nwsMonitoredLocations.first(where: { $0.id == locationID }) else {
            return category.defaultSettings
        }
        return location.settings(for: category)
    }

    var body: some View {
        List {
            Section {
                Toggle("Enabled", isOn: binding(\.enabled))

                VStack(alignment: .leading) {
                    HStack {
                        Text("Volume")
                        Spacer()
                        Text("\(Int(catSettings.volume * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: binding(\.volume), in: 0...1)
                }

                Toggle("Vibration", isOn: binding(\.vibrationEnabled))
            }

            Section {
                Toggle(isOn: binding(\.fadeInEnabled)) {
                    HStack(spacing: 8) {
                        Image(systemName: "sunrise.fill")
                            .foregroundStyle(accent)
                            .frame(width: 24)
                        Text("Fade In")
                    }
                }

                if catSettings.fadeInEnabled {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Fade-In Duration")
                            Spacer()
                            Text(fadeInLabel(catSettings.fadeInDuration))
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(catSettings.fadeInDuration) },
                                set: { binding(\.fadeInDuration).wrappedValue = Int($0) }
                            ),
                            in: 5...120,
                            step: 5
                        )
                    }
                }
            } footer: {
                Text("When enabled, the alert sound starts at near-silence and gradually ramps to full volume.")
            }

            Section {
                let defaultID = settings.alertDefaultSound.isEmpty
                    ? AlarmSoundManager.shared.getDefaultSound().id
                    : settings.alertDefaultSound
                let soundBinding = Binding<String>(
                    get: { catSettings.soundID.isEmpty ? defaultID : catSettings.soundID },
                    set: { binding(\.soundID).wrappedValue = $0 }
                )
                Picker("Sound", selection: soundBinding) {
                    ForEach(AlarmSoundManager.shared.getAllSounds(), id: \.id) { sound in
                        Text(sound.displayName).tag(sound.id)
                    }
                }
                .pickerStyle(.navigationLink)

                Button {
                    isTesting = true
                    Task {
                        await testAlert()
                        isTesting = false
                    }
                } label: {
                    HStack {
                        Spacer()
                        if isTesting {
                            ProgressView()
                                .padding(.trailing, 6)
                        }
                        Text("Test Alert")
                        Spacer()
                    }
                }
                .foregroundStyle(accent)
                .disabled(isTesting)
            }

            Section {
                Button(category.isWarning ? "Apply to All Warnings" : "Apply to All Watches") {
                    applyToSameGroup()
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .foregroundStyle(accent)
            } footer: {
                Text("Copies this alert type's sound, volume, vibration, and fade settings to all other \(category.isWarning ? "warnings" : "watches"). Enabled/disabled state is not changed.")
            }
        }
        .navigationTitle(category.rawValue)
    }

    private func applyToSameGroup() {
        var locs = settings.nwsMonitoredLocations
        guard let locIdx = locs.firstIndex(where: { $0.id == locationID }) else { return }
        let source = catSettings
        let isWarning = category.isWarning
        for cat in NWSAlertCategory.allCases where cat.isWarning == isWarning && cat != category {
            var s = locs[locIdx].settings(for: cat)
            s.soundID = source.soundID
            s.volume = source.volume
            s.vibrationEnabled = source.vibrationEnabled
            s.fadeInEnabled = source.fadeInEnabled
            s.fadeInDuration = source.fadeInDuration
            locs[locIdx].categorySettings[cat.rawValue] = s
        }
        settings.nwsMonitoredLocations = locs
    }

    private func testAlert() async {
        let title = category.rawValue
        let alarmID = MQTTCommandHandler.alertAlarmID(title: title)
        let soundID = catSettings.soundID.isEmpty
            ? (settings.alertDefaultSound.isEmpty
                ? AlarmSoundManager.shared.getDefaultSound().id
                : settings.alertDefaultSound)
            : catSettings.soundID

        let store = PendingAlarmStore.shared
        store.storeAlertInfo(alarmID: alarmID, title: title, message: "Test alert for \(title).")
        store.setPendingAlarmFull(
            alarmID: alarmID,
            label: title,
            missionType: MissionType.alert.rawValue,
            soundID: soundID,
            volumeLevel: catSettings.volume
        )

        await VolumeManager.shared.ensureReady()

        let effectiveVolume = min(max(catSettings.volume, 0.0), 1.0)
        AlarmSoundPlayer.shared.unlock()
        if catSettings.fadeInEnabled {
            VolumeManager.shared.prepareForFadeIn(to: Float(effectiveVolume))
        } else {
            VolumeManager.shared.setSystemVolume(to: Float(effectiveVolume))
        }
        await AlarmSoundPlayer.shared.play(soundID: soundID, initialVolume: catSettings.fadeInEnabled ? 0.0 : 1.0)
        if catSettings.fadeInEnabled {
            try? await Task.sleep(for: .seconds(1))
            VolumeManager.shared.startPlayerFadeIn(duration: TimeInterval(catSettings.fadeInDuration))
        }

        AlarmWindowManager.shared.showAlarm(
            alarmID: alarmID,
            label: title,
            missionType: .alert,
            soundID: soundID
        )
    }

    private func fadeInLabel(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60 == 0 ? "" : "\(seconds % 60)s")".trimmingCharacters(in: .whitespaces)
    }

    /// Create a binding that reads/writes to the location's category settings.
    private func binding<T>(_ keyPath: WritableKeyPath<NWSAlertCategorySettings, T>) -> Binding<T> {
        Binding(
            get: { catSettings[keyPath: keyPath] },
            set: { newValue in
                var locs = settings.nwsMonitoredLocations
                guard let idx = locs.firstIndex(where: { $0.id == locationID }) else { return }
                var updated = catSettings
                updated[keyPath: keyPath] = newValue
                locs[idx].categorySettings[category.rawValue] = updated
                settings.nwsMonitoredLocations = locs
            }
        )
    }
}

// MARK: - Safari View

private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
