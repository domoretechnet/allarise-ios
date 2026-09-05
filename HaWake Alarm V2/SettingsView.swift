//
//  SettingsView.swift
//  HaWake Alarm V2
//
//  Created by Bryan on 3/8/26.
//

import AVFoundation
import CoreLocation
import StoreKit
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var settings: DeviceSettings
    @Bindable var storeManager: StoreManager
    /// Only read to warn, by name, which alarms lose their radio station when
    /// App Persistence is switched off. Settings does not otherwise touch alarms.
    @Query private var alarms: [Alarm]

    /// The app-wide theme accent for the current appearance.
    private var accent: Color { settings.appAccent(for: colorScheme) }
    @State private var showNWSPersistenceWarning = false
    @State private var showRadioPersistenceWarning = false
    /// One-shot advisory shown when MQTT is enabled while persistence is
    /// Dynamic — inbound commands only reach a Dynamic app while it is awake.
    @State private var showDynamicMQTTPrompt = false
    /// Collapsed by default — see the disclosure in `homeAssistantSection`.
    @State private var showingHASettings = false
    /// Bumped on every App Persistence mode change; `PersistenceComparisonTable`
    /// watches it and opens itself so the mode change explains itself.
    @State private var persistenceChangeCount = 0
    /// Where the App Persistence thumb sits, as an index into
    /// `persistenceSliderModes`. Deliberately NOT a direct binding to
    /// `settings.appPersistenceMode`: sliding to Off can raise a warning that
    /// has to be answered before the mode commits, and answering it the safe
    /// way has to put the thumb back where it came from.
    ///
    /// Seeded from the stored mode rather than defaulting to a position, so the
    /// thumb is never briefly drawn somewhere the user is not; `onAppear`
    /// re-syncs it against the injected `settings` for good measure.
    @State private var persistenceSliderIndex =
        Self.persistenceSliderModes.firstIndex(of: DeviceSettings.shared.appPersistenceMode) ?? 2
    @State private var showingLogViewer = false
    @State private var showingWakeLadder = false
    @State private var showingDiagnostics = false
    @State private var showingClearLogsConfirm = false
    @State private var showingResetSettingsConfirm = false
    @State private var showingPurchaseError = false
    @State private var purchaseErrorMessage = ""
    @State private var isProcessingPurchase = false
    @State private var showingPaywall = false
    /// Presents the same app-share sheet the support prompt uses (message + App
    /// Store link), from the "Share with a Friend" button in the Pro section.
    @State private var showingShareApp = false
    #if DEBUG
    @State private var showingAudioDiagnostics = false
    /// Presents the periodic support prompt on demand, so its 30-active-day appearance
    /// can be reviewed without waiting.
    @State private var showingSupportPromptTest = false
    /// Push diagnostics readout — see ProductUpdatePush.fetchDiagnostics.
    @State private var pushDiagnostics: String?
    /// Local mirror of the simulated install date driving the DEBUG date picker.
    /// The picker binds to this (synchronous @State) instead of directly to the async
    /// store override — binding straight to the override would snap the selection back
    /// to its old value before the async write completed.
    @State private var simulatedInstallDate = Date()
    /// Live result of a manual "Refresh Activation Date" tap, shown in the debug UI.
    @State private var activationRefreshStatus: String?
    /// Presents `TermsUpdateView` from the Testing section. The real gate runs in
    /// `HaWake_Alarm_V2App.init`, which is read once at launch — clearing
    /// `agreedTermsVersion` alone would show nothing until the next cold start, so
    /// the reset row presents the screen here as well as arming the launch gate.
    @State private var showingTermsUpdatePreview = false
    #endif
    
    /// Preset UUIDs that are free for all users (no Pro required).
    /// Default = 000...001 (no wallpaper), Neon Silk = 000...000A
    private static let freePresetIDs: Set<UUID> = [
        UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, // Default
        UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, // Neon Silk
    ]
    
    /// When true, auto-navigate to integration settings on appear (used from Status page)
    var initiallyOpenIntegrationSettings: Bool = false
    @State private var navigateToMQTT = false
    @State private var searchText = ""
    @State private var themeRefreshID = UUID()
    @State private var cachedHomePresets: [WallpaperPreset] = []
    @State private var cachedAlarmPresets: [AlarmWallpaperPreset] = []
    /// ID of the theme currently being applied — drives the per-tile progress
    /// spinner. Set to a preset's ID while its (off-main-actor) apply runs.
    @State private var applyingThemeID: UUID?

    // MARK: - Search
    
    private enum SettingsSection: CaseIterable {
        case alarmDefaults, appearance, homeAssistant, reliability, general, pro, testing
        #if DEBUG
        case debug
        #endif
        
        var keywords: [String] {
            switch self {
            case .alarmDefaults:
                return ["alarms", "alarm defaults", "mission", "snooze", "skip", "default", "sound", "volume", "alarm sound", "vibrate", "vibration", "fade", "fade in", "audio", "ringtone", "tone", "sound manager", "custom sound", "import sound"]
            case .appearance:
                return ["appearance", "theme", "color", "accent", "accent color", "tint", "glass", "bigger", "alarm names", "background", "widget", "widgets", "weather", "good morning", "gradient", "gradients", "classic"]
            case .homeAssistant:
                return ["home assistant", "mqtt", "ha api", "hass", "integration", "connection mode", "network", "wifi", "broker", "widget", "arm", "disarm", "command", "commands", "confirm commands", "hold", "duration", "expanded", "bigger"]
            case .reliability:
                return ["reliability", "persistence", "app persistence", "dynamic", "dynamic persistence", "alarm engine", "alarmkit", "keep-alive", "keep alive", "background", "battery", "closure warning", "app closure", "background refresh", "warnings", "armed", "stay awake while armed", "arm"]
            case .general:
                return ["general", "usage data", "crash reports", "analytics", "product updates", "notifications", "privacy", "consent"]
            case .pro:
                return ["pro", "purchase", "unlock", "restore", "debug log", "support", "diagnostics", "wake ladder", "logs"]
            case .testing:
                return ["testing", "pro override", "force pro", "iap test", "mute ringing", "notification sound"]
            #if DEBUG
            case .debug:
                return ["debug", "quick alarm", "quick snooze"]
            #endif
            }
        }
        
        func matches(_ query: String) -> Bool {
            guard !query.isEmpty else { return true }
            let lowered = query.lowercased()
            return keywords.contains { $0.localizedCaseInsensitiveContains(lowered) }
        }
    }
    
    private func showSection(_ section: SettingsSection) -> Bool {
        section.matches(searchText)
    }

    var body: some View {
        NavigationStack {
            Form {
                if showSection(.alarmDefaults) {
                    alarmDefaultsSection
                }

                if showSection(.appearance) {
                    appearanceSection
                }
                
                if showSection(.homeAssistant) {
                    homeAssistantSection
                }

                // NWS Weather Alerts are gated to DEBUG builds only — the
                // feature is retained in the codebase but hidden (and disabled,
                // see DeviceSettings migration) for production users.
                #if DEBUG
                // `debugSimulateNWSRemoved` is the "see it as a production user"
                // switch — it hides this section exactly as a release build does.
                if Locale.current.region?.identifier == "US",
                   !settings.debugSimulateNWSRemoved {
                    nwsAlertsSection
                }
                #endif

                if showSection(.reliability) {
                    reliabilitySection
                    persistenceOptionsSection
                }

                if showSection(.general) {
                    generalSection
                }

                if showSection(.pro) {
                    proSection
                }

                // Every debug-only tool lives in one grouped section
                // (`debugToolsSection`), split into collapsed DisclosureGroups.
                // Rendered when either the Testing or Debug keyword set matches,
                // so existing search terms still surface it.
                #if DEBUG
                if showSection(.testing) || showSection(.debug) {
                    debugToolsSection
                }
                #endif
            }
            .listSectionSpacing(32)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Turn Off App Persistence?", isPresented: $showNWSPersistenceWarning) {
                Button("Turn Off", role: .destructive) {
                    settings.nwsDisclaimerAgreed = false
                    settings.nwsAlertsEnabled = false
                    NWSAlertService.shared.stop()
                    setPersistenceMode(.off)
                }
                // The mode was never committed, so declining has to return the
                // thumb to the mode still in force.
                Button("Cancel", role: .cancel) { syncPersistenceSlider() }
            } message: {
                Text("NWS Weather Alerts are currently active. Turning off App Persistence will also disable NWS alerts.")
            }
            .alert("App Persistence is Dynamic", isPresented: $showDynamicMQTTPrompt) {
                Button("Turn On") { setPersistenceMode(.on) }
                Button("Keep Dynamic", role: .cancel) {}
            } message: {
                Text("Home Assistant commands only reach Allarise while it's awake — charging or near an alarm. Turn App Persistence On for always-on control?")
            }
            .alert("Purchase Error", isPresented: $showingPurchaseError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(purchaseErrorMessage)
            }
            .sheet(isPresented: $showingPaywall) {
                ProPaywallView(storeManager: storeManager)
            }
            .sheet(isPresented: $showingShareApp) {
                ActivityShareSheet(items: [SupportPromptView.shareMessage, AppLinks.appStore]) { _ in
                    showingShareApp = false
                }
            }
            #if DEBUG
            .sheet(isPresented: $showingAudioDiagnostics) {
                AudioDiagnosticsView()
            }
            .sheet(isPresented: $showingTermsUpdatePreview) {
                TermsUpdateView()
            }
            .sheet(isPresented: $showingSupportPromptTest) {
                SupportPromptView(
                    onSupport: { showingPaywall = true },
                    onShared: {},
                    onDismiss: {}
                )
            }
            #endif
            .navigationDestination(isPresented: $navigateToMQTT) {
                MQTTSettingsView(settings: settings)
            }

        }
        // Radio alarms need the app alive at fire time. Without persistence iOS
        // suspends it, the in-app timer never runs, and the AlarmKit failsafe
        // rings the alarm's own tone instead of the station. The alarm still goes
        // off — it just won't be the radio. Shown once per persistence-off
        // period; see radioPersistenceNoticeAcknowledged.
        //
        // A card rather than `.alert`: a system alert renders every button the
        // same way — tinted text on a grey capsule — so "Keep Persistence On",
        // which is the choice we're recommending, looked no different from the
        // destructive one and nothing like the accent-filled buttons used
        // everywhere else in the app. Overlaid on the NavigationStack (not the
        // List) so it dims the toolbar too.
        .overlay {
            if showRadioPersistenceWarning {
                PersistenceConfirmationCard(
                    title: "Radio alarms need App Persistence",
                    message: radioPersistenceWarningText,
                    destructiveTitle: "Turn Off Anyway",
                    keepTitle: "Keep Persistence On",
                    accent: accent,
                    onDestructive: {
                        showRadioPersistenceWarning = false
                        // Order matters: setPersistenceMode re-arms the notice on
                        // the →off transition, so acknowledge AFTER it, not before.
                        setPersistenceMode(.off)
                        settings.radioPersistenceNoticeAcknowledged = true
                    },
                    onKeep: {
                        showRadioPersistenceWarning = false
                        // Nothing was committed — put the thumb back.
                        syncPersistenceSlider()
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.2), value: showRadioPersistenceWarning)
        .sensoryFeedback(.selection, trigger: settings.mqttEnabled)
        .onAppear {
            if initiallyOpenIntegrationSettings {
                // Small delay to let the NavigationStack settle before pushing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    navigateToMQTT = true
                }
            }
        }
    }

    /// The section's identity and its on/off switch in one tall row. This used
    /// to be the Section `header:`; folding the separate "Home Assistant
    /// Integration" toggle into it means the section reads as one thing with one
    /// switch, rather than a heading followed by a row repeating its name.
    private var haSummaryRow: some View {
        HStack(alignment: .center, spacing: 12) {
            // Everything left of the switch is one big expand target — icon,
            // both lines of text, and the empty space between them and the
            // toggle. The Spacer lives INSIDE the button so that gap is
            // tappable too; outside it, the blank area did nothing.
            Button {
                guard settings.mqttEnabled else { return }
                withAnimation(.smooth(duration: 0.25)) { showingHASettings.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Home Assistant")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(settings.mqttEnabled
                             ? "Two-way alarm control & smart home automations"
                             : "Off — turn on to connect over MQTT")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!settings.mqttEnabled)
            .accessibilityLabel("Home Assistant")
            .accessibilityHint(settings.mqttEnabled
                               ? (showingHASettings ? "Hides configuration" : "Shows configuration")
                               : "")

            Toggle("", isOn: $settings.mqttEnabled)
                .labelsHidden()
                .accessibilityLabel("Home Assistant Integration")
        }
        .padding(.top, 8)
        .padding(.bottom, 0)
        // No divider between this row and the chevron under it — they are one
        // control surface, and a separator made the chevron read as a separate
        // list item rather than as this row's own expand affordance.
        .listRowSeparator(.hidden)
        .onChange(of: settings.mqttEnabled) { _, newValue in
            if newValue {
                NetworkMonitor.shared.requestLocationPermission()
                HAIntegrationRouter.shared.activate(settings: settings)
                HAIntegrationRouter.shared.connect(settings: settings)
                if !settings.armButtonEnabled {
                    settings.armButtonEnabled = true
                }
                // If no broker has been configured yet, drop straight into MQTT Settings
                if settings.mqttInternalHost.isEmpty && settings.mqttExternalHost.isEmpty {
                    navigateToMQTT = true
                }
                // One-shot advisory, never a gate: a Dynamic app is only
                // reachable for inbound commands while it is awake, and
                // someone turning MQTT on has just declared they care.
                if settings.appPersistenceMode == .dynamic,
                   !UserDefaults.standard.bool(forKey: "dynamicMQTTPromptShown") {
                    UserDefaults.standard.set(true, forKey: "dynamicMQTTPromptShown")
                    showDynamicMQTTPrompt = true
                }
            } else {
                HAIntegrationRouter.shared.disconnect()
                // Nothing left to disclose once it's off.
                showingHASettings = false
            }
        }
    }

    /// The expand/collapse affordance: a slim full-width row whose only content
    /// is a chevron, so the destinations stay hidden until they're asked for.
    private var haExpandRow: some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) { showingHASettings.toggle() }
        } label: {
            HStack {
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showingHASettings ? 180 : 0))
                Spacer()
            }
            // Explicit height: with zero row insets the glyph had no vertical
            // room and rendered clipped.
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Pulled tight under the summary row; the List's own row padding is what
        // otherwise left a gap that looked like dead space.
        .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 10, trailing: 20))
        .accessibilityLabel(showingHASettings ? "Hide configuration" : "Show configuration")
    }

    // MARK: - NWS Weather Alerts

    private var nwsAlertsSection: some View {
        let caption = "Beta · Weather alerts from the National Weather Service"
        return Section {
            NavigationLink {
                NWSAlertsSettingsView(settings: settings)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "cloud.bolt")
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(accent, in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NWS Weather Alerts")
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if settings.nwsDisclaimerAgreed {
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { settings.nwsDisclaimerAgreed },
                            set: { newValue in
                                if !newValue {
                                    settings.nwsDisclaimerAgreed = false
                                    settings.nwsAlertsEnabled = false
                                    NWSAlertService.shared.stop()
                                }
                            }
                        ))
                        .labelsHidden()
                    }
                }
            }
        } header: {
            sectionHeader("NWS Weather Alerts")
        }
    }

    // MARK: - Home Assistant

    private var homeAssistantSection: some View {
        Section {
            haSummaryRow

            // A slim chevron row is the ONLY expand affordance: the summary row
            // above now carries the on/off switch, and one row that both flips a
            // setting and discloses a subsection would have two conflicting tap
            // targets. Mirrors the alarm editor's bottom-chevron accordions.
            if settings.mqttEnabled {
                haExpandRow
            }

            if settings.mqttEnabled && showingHASettings {
                NavigationLink {
                    MQTTSettingsView(settings: settings)
                } label: {
                    HStack(spacing: 8) {
                        settingsIcon("gearshape.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MQTT Settings")
                            Text("Identity, connection, WiFi networks")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // NO "Commands" row here. Every surface that uses a command —
                // the widget page, alarm swipes, Notes buttons, the picker —
                // carries its own "Manage Commands" link into the same
                // `CommandLibraryView`, so a Settings entry was a fourth door
                // into a room you're already standing in whenever you'd want it.
                NavigationLink {
                    CommandWidgetSettingsView(settings: settings)
                } label: {
                    HStack(spacing: 8) {
                        settingsIcon("square.grid.2x2.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Alarm & Command Widget")
                            Text("Arm/disarm, gestures, layout, and widget list")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                NavigationLink {
                    AlertConfigurationSettingsView(settings: settings)
                } label: {
                    HStack(spacing: 8) {
                        settingsIcon("exclamationmark.shield.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Alert Configuration")
                            Text("Sound, volume, loop, and vibration")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - General Settings

    // Two cards, not one: the mode picker + its "What's App Persistence?"
    // explanation is a wall of information; the toggles that fine-tune it are
    // separate decisions. They are two SIBLING Sections in the List body (see
    // `persistenceOptionsSection`), not one Section here — a List renders each
    // top-level Section as its own inset card, so this split is what gives the
    // clear break under the expanded comparison grid. (Returning both from one
    // property wrapped in a Group merges them back into a single card.)
    private var reliabilitySection: some View {
        Section {
            // Title, control, descriptor and the "What's App Persistence?"
            // disclosure are ONE list row. As two rows the disclosure's
            // expand/collapse changed a row's height under animation, and List
            // mis-sized it — the label rendered blank while the table bled
            // through the clipped bounds. One row also means no separator to
            // hide between them.
            //
            // spacing: 0 with explicit paddings, so each gap is set
            // independently.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    settingsIcon("bolt.circle.fill")
                    Text("App Persistence")
                }

                // A slider rather than the app's usual selectable tiles: the
                // three modes are a single ordered axis (least battery → most
                // readiness), and a slider says that where three equal tiles
                // would not.
                PersistenceModeSlider(
                    modes: Self.persistenceSliderModes,
                    index: $persistenceSliderIndex
                )
                .padding(.top, 14)
                // Fires for user drags AND for programmatic reverts, so the
                // guard is what makes "put the thumb back" not re-request the
                // mode it was reverting from.
                .onChange(of: persistenceSliderIndex) { _, newIndex in
                    let mode = Self.persistenceSliderModes[newIndex]
                    guard mode != settings.appPersistenceMode else { return }
                    requestPersistenceMode(mode)
                }
                // Home Assistant and the MQTT command can change the mode while
                // this screen is open; the thumb has to follow.
                .onChange(of: settings.appPersistenceMode) { _, _ in
                    syncPersistenceSlider()
                }
                .onAppear { syncPersistenceSlider() }

                // All three modes at once, in a grid, behind a disclosure. The
                // Pros/Cons bullet lists this replaces only ever described the
                // mode you were already on, so comparing them meant flipping
                // persistence back and forth. It auto-opens on a mode change,
                // which is also why there is no per-mode summary row here —
                // the highlighted column is the summary.
                PersistenceComparisonTable(
                    mode: settings.appPersistenceMode,
                    openTrigger: persistenceChangeCount
                )
                .padding(.top, 12)
            }
            .padding(.vertical, 4)

        } header: {
            sectionHeader("Reliability")
        }
        // Pull the Options card up close to this one so the two read as a pair
        // (the list's default 32pt still separates them from the next group).
        // The shared "App Persistence" naming in the Options header is what ties
        // them together; the tight gap is what keeps them from looking unrelated.
        .listSectionSpacing(10)
    }

    // The fine-tuning toggles for the persistence mode chosen above, in their
    // own inset card so the expanded comparison grid never reads as one block
    // with the switches below it. A sibling Section in the List body — see the
    // note on `reliabilitySection` for why this is not folded in there.
    //
    // Both toggles are conditional, so the whole card hides under Off — an empty
    // Section still draws a header and an inset gap, which would read as a bug.
    // Off makes alarms pure AlarmKit: no closure warning ever fires and the
    // arm-residency control decides nothing, so neither toggle applies.
    @ViewBuilder
    private var persistenceOptionsSection: some View {
        if settings.appPersistenceMode != .off {
            Section {
                // Dynamic only: when the Alarm & Command Widget's Alarm Control
                // is armed, hold the app resident (like a pending alarm) so
                // inbound HA commands still land. On is always resident and Off
                // never is, so the control only means something under Dynamic.
                if settings.appPersistenceMode == .dynamic {
                    Toggle(isOn: $settings.dynamicResidencyWhenArmed) {
                        HStack(spacing: 8) {
                            settingsIcon("lock.shield.fill")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Stay Awake While Armed")
                                Text("When the Alarm & Command Widget is armed, keep the app awake so Home Assistant can deliver alerts and notify-service messages to it")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Closure warnings exist to protect a persistent app — they fire
                // when persistence is On, or Dynamic while resident.
                Toggle(isOn: $settings.suppressBackgroundRefreshWarning) {
                    HStack(spacing: 8) {
                        settingsIcon("arrow.clockwise.circle.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hide App Closure Warnings")
                            Text("Stops the notification that fires when the app is quit from the task switcher or terminated by iOS")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                sectionHeader("App Persistence Options")
            }
        }
    }

    // MARK: - General

    /// App-level preferences that aren't about whether an alarm fires. Split out
    /// of the Pro section, where the two consent toggles sat next to
    /// Purchase/Restore for no better reason than that being where they were
    /// first written. (Hide App Closure Warnings moved to Reliability — the
    /// warnings only exist when App Persistence is on or Dynamic, so the
    /// control lives with the setting that decides that.)
    private var generalSection: some View {
        Section {
            // GDPR Art. 7 requires withdrawing consent to be as easy as giving
            // it, so both first-run opt-ins are permanently revocable here.
            Toggle(isOn: $settings.analyticsOptIn) {
                HStack(spacing: 8) {
                    settingsIcon("chart.bar.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Usage Data & Crash Reports")
                        Text("Anonymous. Helps find crashes and shows which features get used")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // Withdrawal must actually undo something (GDPR Art. 7), so this
            // stops collection AND purges what was gathered — not just a flag
            // read at next launch.
            .onChange(of: settings.analyticsOptIn) { _, _ in
                Analytics.shared.refreshConsent()
            }

            Toggle(isOn: $settings.productUpdatesOptIn) {
                HStack(spacing: 8) {
                    settingsIcon("sparkles")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Product Updates")
                        Text("Occasional notifications about new features and important changes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // Subscribes/unsubscribes the FCM topic. Opting out also deletes the
            // registration token, so withdrawal removes the identifier rather
            // than just stopping the sends.
            .onChange(of: settings.productUpdatesOptIn) { _, _ in
                ProductUpdatePush.refreshConsent()
                // Retires any announcement still on the alarm list. Hiding it
                // isn't enough — see WhatsNewStore.refreshConsent().
                WhatsNewStore.shared.refreshConsent()
            }

        } header: {
            sectionHeader("General")
        }
    }


    // MARK: - Alarms (Defaults + Sound)

    private var alarmDefaultsSection: some View {
        Section {
            NavigationLink {
                AlarmDefaultsView(settings: settings)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "alarm.fill")
                        .font(.title2)
                        .foregroundStyle(accent)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Alarms")
                            .font(.headline)
                        Text("Default mission, snooze and skip type")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            
            NavigationLink {
                AlarmSoundSettingsView(settings: settings)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.title2)
                        .foregroundStyle(accent)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sound & Volume")
                            .font(.headline)
                        Text("Default sound, volume, vibration & fade in")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            NavigationLink {
                SoundManagerView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.title2)
                        .foregroundStyle(accent)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sound Manager")
                            .font(.headline)
                        Text("Import and manage custom sounds")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Toggle(isOn: $settings.editDuplicatedAlarms) {
                HStack(spacing: 12) {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.title2)
                        .foregroundStyle(accent)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Edit Duplicated Alarms")
                        Text("Automatically open the editor when duplicating an alarm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            sectionHeader("Alarms & Sound")
        }
    }


    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            // Theme quick-apply picker
            themePickerRow

            Toggle(isOn: $settings.showAlarmNamesOnHome) {
                HStack(spacing: 8) {
                    settingsIcon("textformat")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Alarm Names")
                        Text("Display alarm label on home screen cards")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Toggle(isOn: $settings.biggerAlarmRows) {
                HStack(spacing: 8) {
                    settingsIcon("arrow.up.left.and.arrow.down.right")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bigger Alarm Rows")
                        Text("Increase the size of alarm cards on the home screen")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            sectionHeader("Appearance")
        }
    }

    // MARK: - Theme Picker

    /// Horizontal scrolling row of themes that apply both home and alarm presets at once.
    private var themePickerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                settingsIcon("paintpalette.fill")
                Text("Theme")
            }
            
            HStack(spacing: 12) {
                appearanceButton(label: "Light", icon: "sun.max.fill", value: "light")
                appearanceButton(label: "Dark", icon: "moon.fill", value: "dark")
                appearanceButton(label: "System", icon: "circle.lefthalf.filled", value: "system")
            }
            
            Spacer().frame(height: 8)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(cachedHomePresets) { homePreset in
                        let isApplied = settings.appliedHomePresetID == homePreset.id.uuidString
                        let matchingAlarm = cachedAlarmPresets.first { $0.name == homePreset.name }

                        Button {
                            // Themes are free in the support model — every preset applies
                            // directly, no paywall. (`featuresUnlocked` is always true;
                            // flip it in StoreManager to restore paid theme gating.)
                            let isFreePreset = Self.freePresetIDs.contains(homePreset.id)
                            guard storeManager.featuresUnlocked || isFreePreset else {
                                Analytics.shared.log(.paywallShown(source: .theme))
                                showingPaywall = true
                                return
                            }
                            // Ignore taps while an apply is already running.
                            guard applyingThemeID == nil else { return }
                            // Apply the theme with the heavy wallpaper copy/downsample
                            // performed off the main actor. The spinner overlay below
                            // stays live and is cleared only when the real work finishes;
                            // the file copy completes before the applied-ID update so
                            // onChange(of: appliedHomePresetID) in AlarmListView loads the
                            // newly-copied wallpaper images.
                            print("[Theme] Tapped theme: '\(homePreset.name)' id=\(homePreset.id.uuidString) hasLight=\(homePreset.hasLightImage) hasDark=\(homePreset.hasDarkImage)")
                            applyingThemeID = homePreset.id
                            Task {
                                await settings.applyThemeAsync(home: homePreset, alarm: matchingAlarm)
                                print("[Theme] applyThemeAsync done. appliedHomePresetID=\(settings.appliedHomePresetID ?? "nil") appliedAlarmPresetID=\(settings.appliedAlarmPresetID ?? "nil")")
                                applyingThemeID = nil
                            }
                        } label: {
                            ThemeThumbnailView(
                                homePreset: homePreset,
                                settings: settings,
                                isApplied: isApplied,
                                isLocked: !(storeManager.featuresUnlocked || Self.freePresetIDs.contains(homePreset.id))
                            )
                            .overlay {
                                if applyingThemeID == homePreset.id {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(.black.opacity(0.35))
                                        ProgressView()
                                            .progressViewStyle(.circular)
                                            .tint(accent)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(applyingThemeID != nil && applyingThemeID != homePreset.id)
                        .contextMenu {
                            if !homePreset.isBuiltIn {
                                Button(role: .destructive) {
                                    settings.deletePreset(homePreset)
                                    if let alarmPreset = matchingAlarm {
                                        settings.deleteAlarmPreset(alarmPreset)
                                    }
                                    reloadPresets()
                                } label: {
                                    Label("Delete Theme", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 130)
            .id(themeRefreshID)

            // Deliberately INSIDE this VStack rather than a Form row of its own:
            // a sibling row would draw the inset-grouped separator between the
            // wallpapers and the accent, and the accent belongs to the theme
            // directly above it.
            ThemeAccentRow(settings: settings, themeName: appliedThemeName)
        }
        .padding(.vertical, 4)
        .task { reloadPresets() }
        .onReceive(NotificationCenter.default.publisher(for: .presetImported)) { _ in
            reloadPresets()
        }
    }
    
    /// Name of the applied theme, from the already-cached preset list — the
    /// accent picker titles itself with it. nil when nothing is applied, which
    /// the picker renders as a plain "Light Mode" / "Dark Mode" heading.
    private var appliedThemeName: String? {
        guard let id = settings.appliedHomePresetID else { return nil }
        return cachedHomePresets.first { $0.id.uuidString == id }?.name
    }

    private func reloadPresets() {
        var all = settings.loadPresets()
        // If the manifest came back empty, the initial seed likely failed (e.g. bundle
        // resource not found, disk write error). Reset the seed version and retry once.
        if all.isEmpty {
            AppLogger.shared.log("Preset manifest empty — re-seeding built-in presets", category: .general)
            UserDefaults.standard.set(0, forKey: "builtInPresetSeededVersion")
            settings.seedBuiltInPresetsIfNeeded()
            all = settings.loadPresets()
            if all.isEmpty {
                AppLogger.shared.log("Preset manifest still empty after re-seed — seeding may have failed (check bundle resources or disk write permissions)", category: .general)
            }
        }
        // Neon Silk pinned first; Default intentionally omitted from display.
        let freeIDs: [UUID] = [
            UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, // Neon Silk
        ]
        let free = freeIDs.compactMap { id in all.first { $0.id == id } }
        let rest = all.filter { !Self.freePresetIDs.contains($0.id) }
        cachedHomePresets = free + rest
        cachedAlarmPresets = settings.loadAlarmPresets()
        themeRefreshID = UUID()
    }

    // MARK: - Appearance Button

    private func appearanceButton(label: String, icon: String, value: String) -> some View {
        let isSelected = settings.appAppearance == value
        return Button {
            settings.appAppearance = value
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundStyle(isSelected ? accent : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 70)
            .selectableTile(isSelected: isSelected, accent: accent)
        }
        .buttonStyle(.plain)
    }


    // MARK: - Allarise Pro

    private var proSection: some View {
        Section {
            // The support copy, the support/manage CTA and the share button all
            // live in ONE VStack so they read as a single card — a Form puts a
            // gray separator between sibling rows, and there should be no bar
            // between "Support the Project" and "Share with a Friend".
            VStack(alignment: .leading, spacing: 12) {
                if storeManager.isSupporter {
                    HStack(spacing: 6) {
                        Text("Allarise")
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(accent)
                    }
                    .font(.headline)

                    Text("Thank you for supporting this project! Every feature is yours to enjoy.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    // Single entry to the support hub — it adapts to the user's state
                    // (manage subscription, switch to lifetime, contribute again, restore).
                    Button {
                        showingPaywall = true
                    } label: {
                        Text("Support & Manage")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    #if DEBUG
                    if storeManager.forceProForTesting {
                        Text("Debug Mode Active")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    #endif
                } else {
                    HStack(spacing: 6) {
                        Text("Support Allarise")
                        Image(systemName: "heart.fill")
                            .foregroundStyle(accent)
                    }
                    .font(.headline)

                    Text("Allarise is free but we need help keeping things running. If the app has helped you wake up, please consider making a contribution.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        showingPaywall = true
                    } label: {
                        Text("Support the Project")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                // Always offered, supporter or not — anyone can spread the app. Uses
                // the same message + App Store link the support prompt shares, so the
                // two never drift apart.
                Button {
                    showingShareApp = true
                } label: {
                    Label("Share with a Friend", systemImage: "square.and.arrow.up")
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            // Custom disclosure: centered "Diagnostics" with the chevron BELOW
            // the text (not trailing), and no separator above it, so it reads as
            // the foot of the support card rather than a new list row. Same
            // shape as the palette's "More" expander.
            Button {
                withAnimation(.smooth(duration: 0.25)) { showingDiagnostics.toggle() }
            } label: {
                VStack(spacing: 4) {
                    Text("Diagnostics")
                        .font(.subheadline.weight(.medium))
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showingDiagnostics ? 180 : 0))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden, edges: .top)

            if showingDiagnostics {
                Link(destination: AppLinks.faq) {
                    HStack(spacing: 8) {
                        settingsIcon("questionmark.circle")
                        Text("Need help?")
                    }                }

                Button {
                    shareLogFile(AppLogger.shared.exportLogFile())
                } label: {
                    HStack(spacing: 8) {
                        settingsIcon("square.and.arrow.up")
                        Text("Send App Logs")
                    }                }

                // MQTT traffic is by far the highest-volume category (every
                // publish logs a line), so it drowns out alarm/audio entries in
                // the combined export. Exported separately, a broker problem
                // and an alarm problem each get a readable file.
                Button {
                    shareLogFile(AppLogger.shared.exportMQTTLogFile())
                } label: {
                    HStack(spacing: 8) {
                        settingsIcon("antenna.radiowaves.left.and.right")
                        Text("Send MQTT Logs")
                    }                }

                Button {
                    showingLogViewer = true
                } label: {
                    HStack(spacing: 8) {
                        settingsIcon("doc.text.magnifyingglass")
                        Text("View Logs")
                    }                }
                .sheet(isPresented: $showingLogViewer) {
                    LogViewerSheet()
                }

                // The Dynamic-persistence measurement log. Local-only and
                // read-only — see WakeAttemptStore. It lives here rather than in
                // the DEBUG-only Testing section because the question it answers
                // ("did the app actually wake before my alarm?") is one a beta
                // tester on a release build needs to be able to answer too.
                Button {
                    showingWakeLadder = true
                } label: {
                    HStack(spacing: 8) {
                        settingsIcon(symbolName("ladder", fallback: "arrow.up.right.circle"))
                        Text("Wake Ladder")
                    }                }
                .sheet(isPresented: $showingWakeLadder) {
                    WakeLadderSheet()
                }

                Button(role: .destructive) {
                    showingClearLogsConfirm = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                            .frame(width: 24)
                        Text("Clear Logs")
                    }                }
                .confirmationDialog(
                    "Clear all logs?",
                    isPresented: $showingClearLogsConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Clear Logs", role: .destructive) {
                        AppLogger.shared.clear()
                        AppLogger.shared.log("Log cleared by user", category: .general)
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Wipes both the in-memory and on-disk log. Useful before reproducing an issue so the next log export starts fresh.")
                }

                Button(role: .destructive) {
                    showingResetSettingsConfirm = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundStyle(.red)
                            .frame(width: 24)
                        Text("Reset All Settings to Default")
                    }                }
                .confirmationDialog(
                    "Reset all settings?",
                    isPresented: $showingResetSettingsConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Reset All Settings", role: .destructive) {
                        settings.resetAllSettings()
                        reloadPresets()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Restores alarm defaults, appearance, and general settings. Your alarms, MQTT configuration, and NWS locations are not affected.")
                }
            }

        } header: {
            sectionHeader("Allarise Pro")
        }
    }

    private func shareLogFile(_ fileURL: URL?) {
        guard let fileURL else { return }
        let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            // Find the topmost presented view controller
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            activityVC.popoverPresentationController?.sourceView = topVC.view
            topVC.present(activityVC, animated: true)
        }
    }
    
    // MARK: - Testing & Debug Section (DEBUG only)
    //
    // Every debug-only tool lives here, grouped into collapsed DisclosureGroups
    // so the section reads as five rows until you expand the one you need —
    // rather than the ~20-row flat pile this used to be. All of it is compiled
    // out of release builds by the enclosing `#if DEBUG`.

    #if DEBUG
    private var debugToolsSection: some View {
        Section {
            // ── Alarm Timing ──────────────────────────────────────────────
            DisclosureGroup("Alarm Timing") {
                Toggle(isOn: $settings.debugQuickAlarmEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quick Alarm Fire (DEBUG)")
                        Text("Alarms fire in \(settings.debugQuickAlarmDelay)s instead of scheduled time")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if settings.debugQuickAlarmEnabled {
                    Stepper("Alarm delay: \(settings.debugQuickAlarmDelay)s", value: $settings.debugQuickAlarmDelay, in: 5...120, step: 5)
                }

                Toggle(isOn: $settings.debugQuickSnoozeEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quick Snooze (DEBUG)")
                        Text("Snooze fires in \(settings.debugQuickSnoozeDelay)s instead of minutes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if settings.debugQuickSnoozeEnabled {
                    Stepper("Snooze delay: \(settings.debugQuickSnoozeDelay)s", value: $settings.debugQuickSnoozeDelay, in: 5...120, step: 5)
                }
            }

            // ── Pro & Install Date ────────────────────────────────────────
            DisclosureGroup("Pro & Install Date") {
                Toggle(isOn: Binding(
                    get: { storeManager.forceProForTesting },
                    set: { storeManager.forceProForTesting = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Force Pro Unlocked")
                        Text("Bypasses IAP — for internal testing only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Always-visible readout of the real recorded install date, the live
                // activation cutoff, and resulting early-adopter status — shown regardless
                // of whether the install-date override toggle is on.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install Date & Early-Adopter Status")
                    Text(installDateStatusSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(proStatusSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Escape a sticky early-adopter grant earned during prior override testing.
                // Wipes it from Keychain + iCloud and re-derives from the real install date.
                Button("Reset Early-Adopter Grant", role: .destructive) {
                    Task { @MainActor in
                        await storeManager.debugResetEarlyAdopterGrant()
                    }
                }

                // Master switch for the install-date override. Enabling it seeds the
                // override at TODAY — a non-early-adopter date given the current cutoff —
                // then use the date picker below to move it before the cutoff (→ early
                // adopter) or on/after it (→ non-early-adopter). Persists into TestFlight.
                Toggle(isOn: Binding(
                    get: { storeManager.installDateOverrideActive },
                    set: { newValue in
                        Task { @MainActor in
                            if newValue {
                                simulatedInstallDate = Date()
                                await storeManager.setInstallDateOverride(to: Date())
                            } else {
                                await storeManager.disableInstallDateOverride()
                            }
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Override Install Date")
                        Text("Simulate any install date to test the early-adopter gate. Persists into TestFlight so you can test the real IAP purchase flow.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Date picker — only shown while the override is active. Binds to a local
                // @State mirror and writes through onChange so the selection sticks (a direct
                // async binding snaps back before the write lands). Pick a date BEFORE the
                // activation cutoff to simulate an early adopter (Pro auto-granted), or
                // on/after it to simulate a non-early-adopter (paywall active).
                if storeManager.installDateOverrideActive {
                    DatePicker(
                        "Simulated Install Date",
                        selection: $simulatedInstallDate,
                        displayedComponents: [.date]
                    )
                    .onAppear {
                        // Seed the picker from the persisted override so it shows the real
                        // simulated date (e.g. restored from a prior session), not today.
                        if let override = storeManager.installDateOverride {
                            simulatedInstallDate = override
                        }
                    }
                    .onChange(of: simulatedInstallDate) { _, newDate in
                        Task { @MainActor in
                            await storeManager.setInstallDateOverride(to: newDate)
                        }
                    }

                    Text(installDateOverrideDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Clear Override (use real install date)", role: .destructive) {
                        Task { @MainActor in
                            await storeManager.disableInstallDateOverride()
                        }
                    }
                }

                // Manual fetch of the server activation date — lets you verify a server-side
                // change from the device without force-quitting (the app only auto-fetches at
                // launch). Subject to the CDN cache, so allow a few minutes after editing.
                Button {
                    Task { @MainActor in
                        activationRefreshStatus = "Refreshing…"
                        // Raw diagnostic fetch so failures (bad status, stale CDN, parse
                        // error, network) are visible on-device, then apply via the real
                        // refresh path and report the resulting cutoff.
                        let url = URL(string: "https://allarise.app/activationdate.json")!
                        var req = URLRequest(url: url)
                        req.cachePolicy = .reloadIgnoringLocalCacheData
                        req.timeoutInterval = 10
                        do {
                            let (data, resp) = try await URLSession.shared.data(for: req)
                            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                            let body = (String(data: data, encoding: .utf8) ?? "<non-utf8>")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            await storeManager.refreshActivationDate()
                            let fmt = DateFormatter()
                            fmt.dateStyle = .medium
                            fmt.timeStyle = .short
                            activationRefreshStatus = "HTTP \(code) · body: \(body.prefix(48)) · cutoff now: \(fmt.string(from: storeManager.activationCutoff))"
                        } catch {
                            activationRefreshStatus = "Fetch error: \(error.localizedDescription)"
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Refresh Activation Date")
                        Text(activationRefreshStatus ?? "Fetches allarise.app/activationdate.json and updates the cutoff now, without relaunching.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Preview the periodic "support the project" prompt exactly as a user sees it
                // after 30 active-use days — no need to wait or fake the clock. (Supporters
                // never actually see it; this bypasses that check for review only.)
                VStack(alignment: .leading, spacing: 6) {
                    Button("Preview 30-Day Support Prompt") {
                        showingSupportPromptTest = true
                    }
                    Text("Shows the prompt users get after opening the app on 30 separate days. Real trigger: \(SupportPromptManager.shared.activeDayCount) active day(s) so far; shown \(SupportPromptManager.shared.promptCount)/\(SupportPromptResolution.maxPrompts); next at \(SupportPromptManager.shared.nextPromptThreshold.map(String.init) ?? "—").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // ── Banners & Notices ─────────────────────────────────────────
            DisclosureGroup("Banners & Notices") {
                // The warning is normally skipped when App Persistence is off, since
                // suspension is expected there and it fired on every backgrounding.
                // This forces it back on so the notification path can be tested
                // without turning persistence back on.
                Toggle(isOn: $settings.debugForceCloseWarningWhenPersistenceOff) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("App Close Warning When Persistence Off")
                        Text("Debug only. Re-enables the app-close warning notification while App Persistence is off")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $settings.debugHomeBubblesEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Home Screen Test Bubbles")
                        Text("Show the floating weather + alarm screen test bubbles on the home screen")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: NWS removal — user/debug switch
                Toggle(isOn: $settings.debugSimulateNWSRemoved) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Simulate NWS Removed (User View)")
                        Text(settings.debugSimulateNWSRemoved
                             ? "ON — NWS section hidden and service stopped, exactly as in a release build"
                             : "OFF — NWS Weather Alerts section is available for development")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $settings.debugForceNWSRemovalNotice) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Force \"Weather Alerts Removed\" Banner")
                        Text("Shows the one-time notice on the home screen now, ignoring eligibility and any previous dismissal. Clears itself when you tap the banner's ✕.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    NWSRemovalNotice.shared.debugReset()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reset NWS Removal Notice")
                        Text(nwsNoticeDebugCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: Binding(
                    get: { DynamicModeNotice.shared.debugForceShow },
                    set: { DynamicModeNotice.shared.debugForceShow = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Force \"Dynamic Mode\" Banner")
                        Text("Shows the one-time Dynamic-persistence notice on the home screen now, ignoring any previous dismissal. Clears itself when you tap the banner's ✕.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    DynamicModeNotice.shared.debugReset()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reset Dynamic Mode Notice")
                        Text("Clears the dismissal so the notice shows again while the mode is Dynamic · currently \(DynamicModeNotice.shared.debugDismissed ? "dismissed" : "not dismissed")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // ── Audio & Push ──────────────────────────────────────────────
            DisclosureGroup("Audio & Push") {
                // Push delivery has several silent failure modes that look identical
                // from the outside. This prints which stage actually completed, and
                // copies the registration token so Firebase's "Send test message"
                // can target this one device instead of the whole topic.
                VStack(alignment: .leading, spacing: 6) {
                    Button("Check Push Status") {
                        ProductUpdatePush.fetchDiagnostics { pushDiagnostics = $0 }
                    }
                    if let pushDiagnostics {
                        Text(pushDiagnostics)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button("Copy") {
                            UIPasteboard.general.string = pushDiagnostics
                        }
                        .font(.caption)
                    }
                }

                Toggle(isOn: $settings.notifTickSoundDisabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mute Ringing Notification Sound")
                        Text("Test for iOS 27 beta: sends the while-ringing notifications without their silent sound. Watch haptics stop, but this may prevent alarm audio from cutting out")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    // Log the initial snapshot to AppLogger + console, then present
                    // the live-refreshable view so you can watch state transitions
                    // on-screen without digging through the log viewer.
                    _ = AudioDiagnostics.printState(label: "settings-manual")
                    showingAudioDiagnostics = true
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dump Audio State")
                        Text("Shows AVAudioSession, NowPlayingInfo, RemoteCommandCenter, and manager state on-screen. Also logs a snapshot to the Xcode console and audio log category.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // ── Legal & Content ───────────────────────────────────────────
            DisclosureGroup("Legal & Content") {
                // Re-arms the terms gate. Bumping `currentTermsVersion` is the real
                // trigger, but that is a source edit that fires exactly once per
                // device, so there is no way to see the screen a second time without
                // reinstalling. This clears the stored agreement AND presents the
                // screen immediately — tapping "I Agree" on it writes the current
                // version back, so the state ends up where it started.
                Button {
                    settings.agreedTermsVersion = 0
                    showingTermsUpdatePreview = true
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reset Terms Agreement")
                        Text("Clears agreedTermsVersion (now \(settings.agreedTermsVersion), current is \(DeviceSettings.currentTermsVersion)) and shows the terms-update screen. Links open \(AppLinks.host)\(AppLinks.isPinnedAwayFromBuildDefault ? " — PINNED, unpin before prod" : "").")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    VerseOfDayService.shared.resetAndRefetch()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reset Verse of the Day (DEBUG)")
                        Text(verseDebugCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            sectionHeader("Testing & Debug")
        } footer: {
            Text("Debug-only tools, grouped. Install Date Override reshapes which AppDefaults bucket you fall into (see Documents/21-APP-DEFAULTS.md). None of this appears in release builds.")
        }
    }

    /// Breakdown of every input to `effectiveIsPro`, so it's obvious WHY the app is (or
    /// isn't) treating you as Pro — early-adopter is only one of the sources.
    private var proStatusSummary: String {
        var parts = ["purchase: \(storeManager.isPro ? "yes" : "no")",
                     "earlyAdopter: \(storeManager.isEarlyAdopter ? "yes" : "no")"]
        #if DEBUG
        parts.append("forcePro: \(storeManager.forceProForTesting ? "ON" : "off")")
        #endif
        if !storeManager.purchasedProductIDs.isEmpty {
            parts.append("owns: \(storeManager.purchasedProductIDs.sorted().joined(separator: ", "))")
        }
        return "Effective Pro: \(storeManager.effectiveIsPro ? "YES" : "no") — " + parts.joined(separator: ", ")
    }

    /// Always-on summary of the REAL recorded install date, the live activation cutoff,
    /// and early-adopter status. Shown at the top of the Testing section independent of
    /// the override toggle. Notes the override date too when one is active.
    private var installDateStatusSummary: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        let cutoff = fmt.string(from: storeManager.activationCutoff)
        let status = storeManager.isEarlyAdopter ? "✓ Early Adopter (Pro granted)"
                                                  : "✗ Not Early Adopter"
        let base: String
        if let real = StoreManager.storedFirstInstallDate {
            base = "First install: \(fmt.string(from: real)) · cutoff \(cutoff) · \(status)"
        } else {
            base = "No install date recorded yet · cutoff \(cutoff) · \(status)"
        }
        if let override = storeManager.installDateOverride {
            let overrideStr = override >= .distantFuture.addingTimeInterval(-86400)
                ? "distant future" : fmt.string(from: override)
            return base + " · OVERRIDE → \(overrideStr)"
        }
        return base
    }

    /// Computed caption describing the current install date override state, the live
    /// activation cutoff, and the resulting early-adopter status — so it's obvious
    /// which side of the gate you're currently simulating.
    private var installDateOverrideDescription: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        let cutoff = fmt.string(from: storeManager.activationCutoff)
        let status = storeManager.isEarlyAdopter ? "✓ Early Adopter (Pro granted)"
                                                  : "✗ Not Early Adopter (paywall active)"
        if let override = storeManager.installDateOverride {
            if override >= .distantFuture.addingTimeInterval(-86400) {
                return "Distant future · cutoff \(cutoff) · \(status)"
            }
            return "Simulating \(fmt.string(from: override)) · cutoff \(cutoff) · \(status)"
        }
        if let real = StoreManager.storedFirstInstallDate {
            return "Real install \(fmt.string(from: real)) · cutoff \(cutoff) · \(status)"
        }
        return "No install date recorded · cutoff \(cutoff) · \(status)"
    }
    #endif

    // MARK: - Debug Section Helpers
    //
    // The former `debugSection` rows were folded into `debugToolsSection`
    // above (Alarm Timing / Banners & Notices / Legal & Content groups).
    // These captions are still used from there.

    #if DEBUG
    /// Caption for the verse reset row — reflects the last successful fetch so
    /// a tap visibly "did something" (the service is @Observable).
    private var verseDebugCaption: String {
        if let date = VerseOfDayService.shared.lastRefreshDate {
            return "Wipes cached verses/images and re-downloads now · last fetch \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "Wipes cached verses/images and re-downloads the manifest now"
    }

    /// Reports the notice's real stored state so the debug panel shows what is
    /// actually persisted, not just what the toggles were last set to.
    private var nwsNoticeDebugCaption: String {
        let notice = NWSRemovalNotice.shared
        let eligible = notice.debugEligible ? "eligible" : "not eligible"
        let seen = notice.debugDismissed ? "dismissed" : "not dismissed"
        return "Clears both flags so eligibility is re-derived from the NWS disclaimer on next launch · currently \(eligible), \(seen)"
    }
    #endif
    
    // MARK: - Section Header Helper

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 16, weight: .semibold))
            .textCase(nil)
    }
    
    // MARK: - App Persistence

    /// Slider detents, left → right: least battery first, most readiness last.
    /// The order is the control's; `AppPersistenceMode.allCases` is declaration
    /// order and must not be used here.
    private static let persistenceSliderModes: [AppPersistenceMode] = [.off, .dynamic, .on]

    /// Returns the thumb to whatever mode is actually in force. Used after a
    /// declined warning and after an external (Home Assistant) change.
    private func syncPersistenceSlider() {
        let index = Self.persistenceSliderModes.firstIndex(of: settings.appPersistenceMode) ?? 2
        if persistenceSliderIndex != index {
            persistenceSliderIndex = index
        }
    }

    /// `name` when this OS knows the symbol, else `fallback`. A missing SF
    /// Symbol renders as a blank box rather than failing to compile, so the
    /// check has to happen at runtime — `MQTTCommand.symbolExists` is the
    /// existing catalog probe and is reused rather than re-written.
    private func symbolName(_ name: String, fallback: String) -> String {
        MQTTCommand.symbolExists(name) ? name : fallback
    }

    /// Enabled alarms that would lose their station without persistence.
    /// Ephemeral (quick) alarms are excluded — they fire once, imminently, while
    /// the app is still on screen.
    private var radioAlarmLabels: [String] {
        alarms
            .filter { $0.isEnabled && !$0.isEphemeral && ($0.radioStationURL?.isEmpty == false) }
            .map { $0.label.isEmpty ? "Untitled" : $0.label }
    }

    private var radioPersistenceWarningText: String {
        let labels = radioAlarmLabels
        let list: String
        switch labels.count {
        case 0:  list = "Radio alarms"
        case 1:  list = "“\(labels[0])”"
        case 2:  list = "“\(labels[0])” and “\(labels[1])”"
        default: list = "“\(labels[0])”, “\(labels[1])” and \(labels.count - 2) more"
        }
        return """
        \(list) \(labels.count == 1 ? "streams" : "stream") a radio station. \
        Radio needs the app running when the alarm fires, and App Persistence is what keeps it running.

        With it off, \(labels.count == 1 ? "that alarm" : "those alarms") will still go off on time — \
        but you'll hear the alarm tone instead of the station.
        """
    }

    /// The slider's landing point, gated. Moving to Off is the only move that
    /// can be refused: NWS alerts and radio alarms both lose function there, and
    /// silently. Anything that raises a warning leaves the mode UNCOMMITTED —
    /// the warning's own buttons decide, and the thumb is only correct again
    /// once one of them has run.
    private func requestPersistenceMode(_ mode: AppPersistenceMode) {
        guard mode == .off else {
            // Dynamic and On only ever add capability, so nothing to warn about.
            setPersistenceMode(mode)
            return
        }
        if settings.nwsAlertsEnabled || settings.nwsDisclaimerAgreed {
            // Takes priority: turning persistence off disables NWS alerts too,
            // which is a bigger loss than a radio station.
            showNWSPersistenceWarning = true
        } else if !radioAlarmLabels.isEmpty {
            // Radio alarms silently lose their station without persistence —
            // they still ring, on the alarm tone.
            showRadioPersistenceWarning = true
        } else {
            setPersistenceMode(.off)
        }
    }

    /// Commits a mode. Everything downstream — keep-alive start/stop, the
    /// BG-task ladder, the Home Assistant state topic — hangs off
    /// `appPersistenceMode`'s didSet via `DynamicPersistenceController`, so this
    /// must NOT call `BackgroundAudioKeepAlive.applyPersistenceChange` itself:
    /// under `.dynamic` the controller's residency decision is the only correct
    /// answer, and a second caller would fight it.
    private func setPersistenceMode(_ mode: AppPersistenceMode) {
        // Re-arm the radio notice on every →off transition, so someone who
        // switches persistence back on and later off again is told once more.
        if mode == .off && settings.appPersistenceMode != .off {
            settings.radioPersistenceNoticeAcknowledged = false
        }
        settings.appPersistenceMode = mode
        // Reveal the comparison so the mode you just picked explains itself.
        persistenceChangeCount += 1
        // The slider is local state; a commit that arrived via a warning button
        // rather than the drag itself still has to be reflected.
        syncPersistenceSlider()
    }

    /// Fixed-width icon for consistent row alignment across settings
    private func settingsIcon(_ name: String) -> some View {
        Image(systemName: name)
            .foregroundStyle(accent)
            .frame(width: 24)
    }

    private func restorePurchases() {
        isProcessingPurchase = true

        Task {
            await storeManager.restorePurchases()
            isProcessingPurchase = false
        }
    }
}

/// A two-choice confirmation laid out like a system alert, but with the app's own
/// buttons: the safe choice is the accent-filled `.borderedProminent` button used
/// throughout the app, and the destructive one is quieter beside it. `.alert`
/// gives every button identical chrome and ignores `buttonStyle`, so the
/// recommended action could not be made to read as recommended there.
private struct PersistenceConfirmationCard: View {
    let title: String
    let message: String
    let destructiveTitle: String
    let keepTitle: String
    let accent: Color
    let onDestructive: () -> Void
    let onKeep: () -> Void

    var body: some View {
        ZStack {
            // Tapping outside resolves to the SAFE choice — this dialog only ever
            // guards turning something off, so an accidental tap must never be
            // the destructive answer.
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: onKeep)

            // Centred when it fits, scrollable when it doesn't — a system alert
            // scrolls at large Dynamic Type and this has to as well.
            GeometryReader { proxy in
                ScrollView {
                    card
                        .frame(maxWidth: 340)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 40)
                        .frame(maxWidth: .infinity,
                               minHeight: proxy.size.height,
                               alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onKeep)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .destructive, action: onDestructive) {
                Text(destructiveTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            // The recommended choice, in the app's standard accent button.
            Button(action: onKeep) {
                Text(keepTitle)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(accent)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
    }
}


struct AddSSIDSheet: View {
    var settings: DeviceSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var manualSSID = ""
    @State private var detectedSSID: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let ssid = detectedSSID {
                        if !settings.homeSSIDs.contains(ssid) {
                            Button {
                                addSSID(ssid)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "wifi")
                                        .foregroundStyle(DeviceSettings.shared.appAccent(for: colorScheme))
                                        .frame(width: 24)
                                    VStack(alignment: .leading) {
                                        Text("Add Current Network")
                                            .font(.headline)
                                        Text(ssid)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } else {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("\(ssid) already added")
                            }
                        }
                    } else {
                        undetectedNetworkContent
                    }
                } header: {
                    Text("Current Network")
                }

                Section {
                    TextField("Network Name (SSID)", text: $manualSSID)
                        .autocapitalization(.none)

                    Button("Add Manually") {
                        addSSID(manualSSID)
                    }
                    .disabled(manualSSID.isEmpty)
                } header: {
                    Text("Manual Entry")
                } footer: {
                    Text("Enter the exact WiFi network name (SSID).")
                }
            }
            .navigationTitle("Add Home Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                // SSID detection needs Location "When In Use" — request it if the user
                // hasn't decided yet, then force a fresh read instead of trusting the
                // possibly-stale cached value.
                if NetworkMonitor.shared.isLocationNotDetermined {
                    NetworkMonitor.shared.requestLocationPermission()
                }
                NetworkMonitor.shared.refreshSSID()
                detectedSSID = NetworkMonitor.shared.currentSSID
            }
            .onChange(of: NetworkMonitor.shared.currentSSID) { _, newSSID in
                detectedSSID = newSSID
            }
        }
    }

    /// Shown when no SSID is detected — explains why and gives a path forward, instead
    /// of a dead-end "not detected". iOS returns nil for the SSID without Location
    /// permission, on the Simulator, or when Wi-Fi is off/transitioning.
    @ViewBuilder private var undetectedNetworkContent: some View {
        if NetworkMonitor.shared.isLocationDenied {
            VStack(alignment: .leading, spacing: 8) {
                Text("Location access is required to detect your Wi-Fi network name. Enable it for Allarise in Settings, or add your network manually below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        } else if NetworkMonitor.shared.isLocationNotDetermined {
            HStack(spacing: 8) {
                ProgressView()
                Text("Requesting location access…")
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn't detect your Wi-Fi network. Make sure Wi-Fi is on and connected, or add it manually below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    NetworkMonitor.shared.refreshSSID()
                    detectedSSID = NetworkMonitor.shared.currentSSID
                }
            }
        }
    }

    private func addSSID(_ ssid: String) {
        guard !ssid.isEmpty, !settings.homeSSIDs.contains(ssid) else { return }
        settings.homeSSIDs.append(ssid)
        NetworkMonitor.shared.refreshSSID()
        manualSSID = ""
        dismiss()
    }
}

/// A custom slider that uses its own DragGesture to avoid conflicts with
/// Form/List scroll views. The drag gesture is marked as high priority so
/// it wins over the scroll view's pan gesture recognizer.
struct FormSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double?
    /// Fill color for the filled track. Leave nil — as 7 of the 10 call sites do —
    /// to follow the app accent.
    ///
    /// This used to default to `.accentColor`, which sounds right and is not:
    /// `Color.accentColor` resolves the asset catalog's `AccentColor`, and this
    /// project ships that colorset EMPTY, so it collapsed to system blue and
    /// followed neither the theme accent nor the user's per-theme override. Every
    /// caller that relied on the default therefore drew a blue track inside a
    /// section whose every other control had already recolored (al-nl9).
    ///
    /// `FormSlider` is a hand-rolled control — the fill is a `RoundedRectangle`,
    /// not a UIKit slider — so it cannot inherit the ambient `.tint()` the way a
    /// stock `Slider` does. Resolving here is what makes the root tint reach it.
    var tint: Color? = nil
    var onEditingChanged: ((Bool) -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    /// The explicit tint when a caller passed one, else the app accent.
    private var resolvedTint: Color {
        tint ?? DeviceSettings.shared.appAccent(for: colorScheme)
    }

    @State private var isDragging = false
    /// Tracks whether the initial touch landed near the thumb
    @State private var touchValid = false

    /// How close (in points) the initial touch must be to the thumb center
    private let thumbHitRadius: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let thumbX = trackWidth * CGFloat(fraction)

            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.systemGray4))
                    .frame(height: 6)

                // Filled track
                RoundedRectangle(cornerRadius: 4)
                    .fill(resolvedTint)
                    .frame(width: max(0, thumbX), height: 6)

                // Thumb — pill-shaped, matching iOS 26 native slider (37×24pt)
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    .frame(width: 37, height: 24)
                    .offset(x: max(0, min(thumbX - 18.5, trackWidth - 37)))
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            // Only start dragging if the touch began near the thumb
                            let thumbCenter = thumbX
                            let touchX = drag.startLocation.x
                            guard abs(touchX - thumbCenter) <= thumbHitRadius else { return }
                            isDragging = true
                            touchValid = true
                            onEditingChanged?(true)
                        }
                        guard touchValid else { return }
                        let fraction = Double(drag.location.x / trackWidth)
                        let clamped = min(max(fraction, 0), 1)
                        var newValue = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
                        if let step {
                            newValue = (newValue / step).rounded() * step
                        }
                        value = min(max(newValue, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        if touchValid {
                            onEditingChanged?(false)
                        }
                        isDragging = false
                        touchValid = false
                    }
            )
        }
        .frame(height: 36)
    }
}

// MARK: - App Persistence Slider

/// A discrete three-detent slider: Off – Dynamic – On.
///
/// A sibling of `FormSlider` rather than a use of it. `FormSlider` only accepts
/// a drag that STARTS within 30pt of the thumb, which is right for a continuous
/// value and wrong for three named detents — tapping the word "Dynamic" has to
/// move the thumb there. The 6pt track, the fill, and the 37×24 pill thumb are
/// taken from it verbatim so the two read as one control family.
///
/// There is no `tint` parameter, on purpose. Like `FormSlider` this is a
/// hand-rolled control (the fill is a `RoundedRectangle`, not a UIKit slider),
/// so it cannot inherit the ambient `.tint()`; and `Color.accentColor` is not an
/// option because this project ships an EMPTY `AccentColor` colorset, which
/// collapses it to system blue (al-nl9). The app accent is resolved here, the
/// same way `FormSlider.resolvedTint` does it.
private struct PersistenceModeSlider: View {
    let modes: [AppPersistenceMode]
    @Binding var index: Int

    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { DeviceSettings.shared.appAccent(for: colorScheme) }

    private let thumbWidth: CGFloat = 37
    private let thumbHeight: CGFloat = 24

    /// True once a touch that began on the thumb has been accepted as a drag.
    @State private var isDragging = false
    /// How close (pt) the initial touch must land to the thumb to start a drag —
    /// the same guard `FormSlider` uses.
    private let thumbHitRadius: CGFloat = 30
    /// Max travel (pt) a touch may have on release to still count as a tap rather
    /// than a stray scroll.
    private let tapSlop: CGFloat = 12

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                // The thumb travels between its own half-widths, so the detent
                // centres line up with the ends of the track rather than
                // hanging off them.
                let travel = max(1, geo.size.width - thumbWidth)
                let spacing = travel / CGFloat(max(1, modes.count - 1))
                let thumbX = spacing * CGFloat(clampedIndex)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemGray4))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(accent)
                        .frame(width: thumbX + thumbWidth / 2, height: 6)

                    // Detent pips, so the three stops are visible before the
                    // thumb is moved — a bare track reads as continuous.
                    ForEach(modes.indices, id: \.self) { i in
                        Circle()
                            .fill(Color(.systemGray))
                            .frame(width: 4, height: 4)
                            .offset(x: thumbWidth / 2 + spacing * CGFloat(i) - 2)
                            .opacity(i == clampedIndex ? 0 : 0.7)
                    }

                    RoundedRectangle(cornerRadius: 12)
                        .fill(.white)
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                        .frame(width: thumbWidth, height: thumbHeight)
                        .offset(x: thumbX)
                }
                .frame(height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    // Two intents share one gesture: a TAP on a detent selects it,
                    // and a DRAG of the thumb slides between them. The naive version
                    // — `minimumDistance: 0` snapping on every `onChanged` — also
                    // fired on the first touch of any scroll that grazed the track,
                    // so a diagonal swipe down the Settings Form silently changed the
                    // mode (the user "kept moving it on accident").
                    //
                    // Guard both paths the way `FormSlider` guards its drag:
                    //  • a touch only becomes a DRAG if it STARTS within `thumbHitRadius`
                    //    of the thumb — a scroll grazing elsewhere never engages;
                    //  • a touch only counts as a TAP on release if the finger barely
                    //    moved (`tapSlop`) — a scroll has large travel, so it is ignored.
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard isDragging
                                || abs(drag.startLocation.x - thumbX) <= thumbHitRadius
                            else { return }
                            isDragging = true
                            select(at: drag.location.x, spacing: spacing)
                        }
                        .onEnded { drag in
                            if isDragging {
                                select(at: drag.location.x, spacing: spacing)
                            } else if hypot(drag.translation.width, drag.translation.height) <= tapSlop {
                                // A tap that never became a drag — select the tapped detent.
                                select(at: drag.location.x, spacing: spacing)
                            }
                            isDragging = false
                        }
                )
                .animation(.smooth(duration: 0.18), value: clampedIndex)
            }
            .frame(height: 36)

            labels
        }
        .sensoryFeedback(.selection, trigger: clampedIndex)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("App Persistence")
        .accessibilityValue(modes[clampedIndex].displayName)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: setIndex(clampedIndex + 1)
            case .decrement: setIndex(clampedIndex - 1)
            @unknown default: break
            }
        }
    }

    /// Endpoints are anchored to the ends of the track, not centred in equal
    /// thirds — equal thirds put "Off" a long way right of the detent it names.
    private var labels: some View {
        HStack(spacing: 4) {
            ForEach(modes.indices, id: \.self) { i in
                Text(modes[i].displayName)
                    .font(.caption)
                    .fontWeight(i == clampedIndex ? .semibold : .regular)
                    .foregroundStyle(i == clampedIndex ? accent : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: labelAlignment(i))
            }
        }
    }

    private func labelAlignment(_ i: Int) -> Alignment {
        if i == 0 { return .leading }
        if i == modes.count - 1 { return .trailing }
        return .center
    }

    private var clampedIndex: Int {
        min(max(index, 0), modes.count - 1)
    }

    private func select(at x: CGFloat, spacing: CGFloat) {
        let raw = (x - thumbWidth / 2) / max(spacing, 1)
        setIndex(Int(raw.rounded()))
    }

    private func setIndex(_ new: Int) {
        let clamped = min(max(new, 0), modes.count - 1)
        guard clamped != index else { return }
        index = clamped
    }
}

// MARK: - Theme Thumbnail View

/// In-memory cache for downsampled theme preview thumbnails. Without it, every
/// Settings open re-decodes two wallpaper JPGs per theme card from disk — slow
/// with this many themes. Keyed by file path + modification date so an edited
/// custom preset's thumbnail refreshes on its own.
/// `nonisolated` so `thumbnail(at:)` can run inside the `Task.detached` that decodes
/// preview images off the main thread (default-MainActor isolation would otherwise infer
/// `@MainActor`). `NSCache` is thread-safe.
nonisolated private enum ThemeThumbnailCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func thumbnail(at url: URL, maxDimension: CGFloat) -> UIImage? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let modDate = attrs?[.modificationDate] as? Date else { return nil }
        let key = "\(url.path)|\(modDate.timeIntervalSince1970)|\(Int(maxDimension))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = DeviceSettings.downsampledImage(at: url, maxDimension: maxDimension) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// A compact theme preview card showing light+dark wallpaper thumbnails with the theme name.
struct ThemeThumbnailView: View {
    let homePreset: WallpaperPreset
    let settings: DeviceSettings
    let isApplied: Bool
    var isLocked: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @State private var lightThumb: UIImage?
    @State private var darkThumb: UIImage?

    private var accent: Color { settings.appAccent(for: colorScheme) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                HStack(spacing: 2) {
                    PresetMockupThumbnail(
                        wallpaper: lightThumb,
                        glassVariant: homePreset.lightGlassVariant,
                        clearDimming: homePreset.lightGlassClearDimming,
                        tintRed: homePreset.lightGlassTintRed,
                        tintGreen: homePreset.lightGlassTintGreen,
                        tintBlue: homePreset.lightGlassTintBlue,
                        tintOpacity: homePreset.lightGlassTintOpacity
                    )
                    PresetMockupThumbnail(
                        wallpaper: darkThumb,
                        glassVariant: homePreset.darkGlassVariant,
                        clearDimming: homePreset.darkGlassClearDimming,
                        tintRed: homePreset.darkGlassTintRed,
                        tintGreen: homePreset.darkGlassTintGreen,
                        tintBlue: homePreset.darkGlassTintBlue,
                        tintOpacity: homePreset.darkGlassTintOpacity
                    )
                }
                .opacity(isLocked ? 0.45 : 1)

                if isApplied {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, accent)
                        .offset(x: 4, y: 4)
                } else if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.55), in: Circle())
                        .offset(x: 4, y: 4)
                }
            }

            Text(homePreset.name)
                .font(.caption2)
                .foregroundStyle(isApplied ? .primary : .secondary)
                .lineLimit(1)
        }
        .task {
            let preset = homePreset
            let (light, dark) = await Task.detached(priority: .userInitiated) {
                let presetsDir = DeviceSettings.presetsDirectory
                    .appendingPathComponent(preset.id.uuidString)
                let l: UIImage? = preset.hasLightImage
                    ? ThemeThumbnailCache.thumbnail(at: presetsDir.appendingPathComponent("light.jpg"), maxDimension: 120)
                    : nil
                let d: UIImage? = preset.hasDarkImage
                    ? ThemeThumbnailCache.thumbnail(at: presetsDir.appendingPathComponent("dark.jpg"), maxDimension: 120)
                    : nil
                return (l, d)
            }.value
            lightThumb = light
            darkThumb = dark
        }
    }
}

// MARK: - Log Viewer Sheet

private struct LogViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logText: String = ""
    @State private var logLines: [String] = []
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 1)
                    }
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("Debug Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = logText
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "Copied!" : "Copy All", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            }
        }
        .onAppear {
            logText = AppLogger.shared.exportLogText()
            logLines = logText.components(separatedBy: "\n")
        }
    }
}

// MARK: - Wake Ladder Sheet

/// Read-only view of `WakeAttemptStore` — every BGAppRefreshTask submission,
/// every ladder wake, and every alarm fire, newest first.
///
/// The question it exists to answer is "did the app actually wake before my
/// alarm, and which path rang it?", so the 14-day summary sits above the raw
/// history: the counts are the answer, the records are the evidence. No export
/// button — these records never leave the device (see the file header on
/// WakeAttemptStore), and a share sheet would be the first thing to change that.
private struct WakeLadderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var records: [WakeAttemptRecord] = []

    private static let summaryWindow: TimeInterval = 14 * 24 * 60 * 60

    /// Newest first. `WakeAttemptRecord.id` is its timestamp, which two records
    /// written in the same instant would share, so the ForEach keys on position
    /// instead.
    private var newestFirst: [WakeAttemptRecord] {
        records.sorted { $0.timestamp > $1.timestamp }
    }

    private var recent: [WakeAttemptRecord] {
        let cutoff = Date().addingTimeInterval(-Self.summaryWindow)
        return records.filter { $0.timestamp >= cutoff }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let wakes = counts(kind: "ladderWake")
                    let fires = counts(kind: "alarmFired")
                    if wakes.isEmpty && fires.isEmpty {
                        Text("Nothing recorded in the last 14 days.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        summaryRow(title: "Ladder wakes", counts: wakes)
                        summaryRow(title: "Alarm fires", counts: fires)
                    }
                } header: {
                    Text("Last 14 Days")
                } footer: {
                    Text("Recorded on this device only. Nothing here is uploaded.")
                }

                Section("History") {
                    if newestFirst.isEmpty {
                        Text("No records yet. The ladder only runs while App Persistence is Dynamic or On.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(newestFirst.enumerated()), id: \.offset) { _, record in
                            recordRow(record)
                        }
                    }
                }
            }
            .navigationTitle("Wake Ladder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { records = WakeAttemptStore.shared.allRecords() }
    }

    // MARK: Pieces

    /// Outcome → count for one record kind, busiest first so the common case
    /// leads.
    private func counts(kind: String) -> [(label: String, count: Int)] {
        Dictionary(grouping: recent.filter { $0.kind == kind }, by: { $0.outcome ?? "unknown" })
            .map { (label: $0.key, count: $0.value.count) }
            .sorted { $0.count == $1.count ? $0.label < $1.label : $0.count > $1.count }
    }

    private func summaryRow(title: String, counts: [(label: String, count: Int)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(counts.isEmpty
                 ? "None"
                 : counts.map { "\($0.label) \($0.count)" }.joined(separator: " · "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func recordRow(_ record: WakeAttemptRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.timestamp.formatted(date: .abbreviated, time: .standard))
                    .font(.caption.monospaced())
                Spacer(minLength: 8)
                Text(record.kind)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(detailLine(record))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// outcome · charging state · Low Power Mode · battery.
    private func detailLine(_ record: WakeAttemptRecord) -> String {
        var parts: [String] = []
        if let outcome = record.outcome { parts.append(outcome) }
        parts.append(record.charging ? "charging" : "on battery")
        if record.lowPowerMode { parts.append("LPM") }
        // UIDevice reports -1 when battery monitoring was off at record time.
        parts.append(record.batteryLevel < 0 ? "battery —" : "\(Int((record.batteryLevel * 100).rounded()))%")
        return parts.joined(separator: " · ")
    }
}

#Preview {
    SettingsView(
        settings: DeviceSettings.shared,
        storeManager: StoreManager.shared
    )
}
