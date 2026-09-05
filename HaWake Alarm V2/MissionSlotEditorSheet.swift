//
//  MissionSlotEditorSheet.swift
//  HaWake Alarm V2
//
//  The pop-out editor for a single mission slot. Presented as a sheet anchored on
//  the host editor's Form root — NEVER from a Form row (that tears the editor
//  sheet down; see the stationBrowserMode comment in AlarmEditorView).
//
//  Flow: pick a mission TYPE from the pastel grid, pick a DIFFICULTY from a row of
//  preset chips, and — only if more control is wanted — expand the detailed
//  per-type controls. "Try It Out" stays available once a difficulty is chosen.
//  "No Mission" clears the slot; clearing a middle slot compacts the sequence left
//  (done by the host on dismiss).
//
//  Home Assistant is offered ONLY when editing slot 1 (target .slot(0)) and MQTT
//  is enabled. When the slot's type is Home Assistant, a second, duplicate
//  "Fallback Mission" selector appears below the HA description — same pastel
//  type-grid style over the eligible fallback tiles (None / Shake / Math /
//  Balance) writing the slot's `haFallback*` fields. That fallback runs if Home
//  Assistant is unreachable, and "Try It Out" previews it.
//

import SwiftUI

/// Which box the pop-out edits.
enum MissionSlotTarget: Equatable {
    case slot(Int)   // an existing, filled unified slot index (0 = slot 1)
    case add         // the next empty box — commits a brand-new slot
}

/// Identifiable request so the host can drive `.sheet(item:)` from its Form root.
struct MissionSlotEditRequest: Identifiable {
    let target: MissionSlotTarget
    var id: String {
        switch target {
        case .slot(let i): return "slot-\(i)"
        case .add:         return "add"
        }
    }
}

struct MissionSlotEditorSheet: View {
    let target: MissionSlotTarget
    /// Slot 1 (source of truth, owned by the host editor).
    @Binding var mission: Mission
    /// Slots 2..5 (source of truth, owned by the host editor).
    @Binding var extraMissions: [Mission]
    /// Alarm-level grace-period override state, owned by the host editor and
    /// shared across every slot's sheet (one value for the whole alarm).
    /// `useCustomGracePeriod == false` (or value 0) means Auto.
    @Binding var useCustomGracePeriod: Bool
    @Binding var customGracePeriod: Double
    let settings: DeviceSettings
    let mqttEnabled: Bool

    /// Draft-based editing: every control in the sheet mutates this local snapshot
    /// of the edited slot's Mission — NOT the alarm's mission bindings — so that
    /// browsing/previewing mission types sticks nothing to the card until the user
    /// taps Save. Snapshotted on init; written back to the slot binding on Save.
    @State private var draft: Mission
    /// Draft copies of the alarm-level grace override (shared across all slots).
    /// Snapshotted on init, written back to the shared bindings on Save.
    @State private var draftUseCustomGrace: Bool
    @State private var draftCustomGrace: Double
    /// Whether a mission TYPE has actually been chosen for this slot — drives the
    /// grid selection highlight and gates every section below the grid. False for
    /// add-mode and for the untouched default slot (so nothing is pre-selected);
    /// true once the user taps any tile, and true on open when editing a real,
    /// already-configured slot. In `.add` mode it also decides whether Save appends
    /// the draft (an untouched add = nothing to add, just dismiss).
    @State private var typeChosen: Bool

    /// Try It Out preview, presented from THIS sheet's own root so the picker
    /// stays open behind it — the user can preview several mission types in a
    /// row before committing one to the slot.
    @State private var previewRequest: MissionPreviewRequest?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { settings.appAccent(for: colorScheme) }

    /// Sheet size — opens at `.large` so the picker uses the bigger screen, but
    /// the user can still drag down to `.medium`.
    @State private var detent: PresentationDetent = .large
    /// Paywall shown when a locked (Pro) mission type is tapped.
    @State private var showingPaywall = false

    init(target: MissionSlotTarget,
         mission: Binding<Mission>,
         extraMissions: Binding<[Mission]>,
         useCustomGracePeriod: Binding<Bool>,
         customGracePeriod: Binding<Double>,
         settings: DeviceSettings,
         mqttEnabled: Bool) {
        self.target = target
        self._mission = mission
        self._extraMissions = extraMissions
        self._useCustomGracePeriod = useCustomGracePeriod
        self._customGracePeriod = customGracePeriod
        self.settings = settings
        self.mqttEnabled = mqttEnabled

        // Snapshot the edited slot's Mission into the draft. Add-mode starts from a
        // fresh Mission() (type .none); picking a type just mutates the draft.
        let initialDraft: Mission
        switch target {
        case .slot(let i):
            if i == 0 {
                initialDraft = mission.wrappedValue
            } else {
                let extraIndex = i - 1
                let extras = extraMissions.wrappedValue
                initialDraft = extraIndex < extras.count ? extras[extraIndex] : Mission()
            }
        case .add:
            initialDraft = Mission()
        }
        _draft = State(initialValue: initialDraft)
        _draftUseCustomGrace = State(initialValue: useCustomGracePeriod.wrappedValue)
        _draftCustomGrace = State(initialValue: customGracePeriod.wrappedValue)

        // Nothing is pre-selected for an add or for the untouched default slot 1
        // (plain single-tap, no explicit Tap choice). Editing any other existing
        // slot opens on its already-chosen type. Extra slots (index ≥ 1) are always
        // real, deliberately-added steps, so they count as chosen.
        let chosen: Bool
        switch target {
        case .slot(let i):
            if i == 0 {
                chosen = initialDraft.type != .none
                    || initialDraft.tapDismissIsMission
                    || initialDraft.tapExplicitlyChosen
            } else {
                chosen = true
            }
        case .add:
            chosen = false
        }
        _typeChosen = State(initialValue: chosen)
    }

    /// Number of configured slots (slot 1 + extras). A Tap (`.none`) slot is a real
    /// slot; only the truly-empty default (slot 1 a plain single-tap, no extras)
    /// counts as zero. Compaction keeps slots packed 1..N.
    private var filledCount: Int {
        if mission.type == .none && !mission.tapDismissIsMission && !mission.tapExplicitlyChosen && extraMissions.isEmpty {
            return 0
        }
        return 1 + extraMissions.count
    }

    private func slotMission(at index: Int) -> Mission {
        if index == 0 { return mission }
        let extraIndex = index - 1
        return extraIndex < extraMissions.count ? extraMissions[extraIndex] : Mission()
    }

    private func missionBinding(at index: Int) -> Binding<Mission> {
        if index == 0 { return $mission }
        let extraIndex = index - 1
        return Binding(
            get: { extraIndex < extraMissions.count ? extraMissions[extraIndex] : Mission() },
            set: { if extraIndex < extraMissions.count { extraMissions[extraIndex] = $0 } }
        )
    }

    /// The unified index of the concrete slot being edited. In `.add` mode this is
    /// nil (the draft isn't tied to a slot until Save appends it).
    private var workingIndex: Int? {
        switch target {
        case .slot(let i): return i
        case .add:         return nil
        }
    }

    /// Binding to the DRAFT — every control edits this local snapshot, never the
    /// alarm's slot bindings. Kept optional to preserve the existing call sites.
    private var slotBinding: Binding<Mission>? { $draft }

    /// The draft's chosen type (`.none` before a type is picked in add mode).
    private var slotType: MissionType { draft.type }

    /// True only when editing slot 1 (index 0). HA is offered here exclusively.
    private var isSlotOne: Bool {
        // Once a slot is resolved (existing target, or an add that committed a
        // type), key off its index. Before an add commits, the next box is slot 1
        // only when the sequence is empty.
        if let idx = workingIndex { return idx == 0 }
        return filledCount == 0
    }

    // MARK: - Fallback (Home Assistant slot only)

    /// Write-through binding to the HA slot's mission when the current slot is HA —
    /// the home for the `haFallback*` fields the fallback picker edits.
    private var haSlotBinding: Binding<Mission>? {
        guard slotType == .homeAssistant else { return nil }
        return slotBinding
    }

    /// The chosen fallback type (`haFallbackMission` on the HA slot).
    private var fallbackType: MissionType {
        haSlotBinding?.wrappedValue.haFallbackMission ?? .none
    }

    private var displayNumber: Int {
        (workingIndex.map { $0 + 1 }) ?? (filledCount + 1)
    }

    private var navTitle: String { "Mission \(displayNumber)" }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    typeGrid
                    // The type description, Math example, and every configuration
                    // section below appear only once a type is actually chosen — an
                    // untouched slot shows the bare grid with no tile selected.
                    if typeChosen, let desc = description(for: slotType) {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // Math example lives with the type description — same card.
                    if typeChosen && slotType == .math {
                        MathProblemPreviewRow(difficulty: slotBinding?.wrappedValue.mathDifficulty ?? .easy)
                    }
                }

                if typeChosen {
                    if slotType == .homeAssistant {
                        // Home Assistant: an info line plus the duplicate Fallback
                        // Mission selector (with its own config below when chosen).
                        Section {
                            Text("Home Assistant dismisses the alarm via MQTT. Pick a Fallback Mission below to run instead if Home Assistant is unreachable.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        fallbackSelectorSection

                        if fallbackType != .none {
                            if fallbackType.isPreviewable {
                                tryItOutSection(previewMission)
                            }
                            fallbackConfigurationSection
                        }
                    } else if slotType == .none {
                        // Tap slot: dismiss-mode config instead of a difficulty card,
                        // plus a live preview of the tap/hold chip.
                        tryItOutSection(previewMission)
                        tapConfigurationSection
                    } else if slotType.isPreviewable {
                        tryItOutSection(previewMission)
                        configurationSection
                    }
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { commitDraft() }
                        .fontWeight(.semibold)
                }
            }
        }
        // Anchored on the sheet's own root (not a Form row), so the picker stays
        // open underneath — dismissing the preview lands back in this sheet.
        .fullScreenCover(item: $previewRequest) { request in
            MissionPreviewView(mission: request.mission, settings: settings)
        }
        // Same rule as the preview above: anchored on this sheet's root so the
        // picker survives underneath.
        .sheet(isPresented: $showingPaywall) {
            ProPaywallView(storeManager: StoreManager.shared)
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        // Pin the sheet's backing to the Form's grouped background. Without this,
        // iOS swaps the sheet's underlying material between the medium and large
        // detents (medium reads noticeably grayer), so the background appeared to
        // shift as the sheet resized. Using the semantic grouped-background color
        // (not a hardcoded gray) keeps it identical at both detents and correct in
        // light AND dark.
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
    }

    /// One-to-two line secondary description of a mission type, shown under the
    /// type grids. Shared by the main type grid and the fallback grid.
    private func description(for type: MissionType) -> String? {
        MissionConfigInfo.description(for: type, slotOne: isSlotOne)
    }

    // MARK: - Type Grid

    private var gridTypes: [MissionType] {
        var types = MissionType.userVisible
        // Home Assistant is slot-1-only, and only when the Home Assistant
        // integration (MQTT) is enabled in Settings — intentionally hidden
        // otherwise.
        if !mqttEnabled || !isSlotOne {
            types.removeAll { $0 == .homeAssistant }
        }
        return types
    }

    private var typeGrid: some View {
        let types = gridTypes
        // Extra slots get a DISTINCT "No Mission" clear tile that removes the slot.
        // (Tap is now a real mission in the `.none` tile, so clearing needs its own
        // action.) Slot 1 is the alarm anchor and can't be cleared, so no clear tile.
        let showClearTile = !isSlotOne
        let tileCount = types.count + (showClearTile ? 1 : 0)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12),
                            count: tileCount <= 4 ? max(1, tileCount) : 3)
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Array(types.enumerated()), id: \.element) { index, type in
                // `.none` is the Tap mission tile in every slot now (animated Tap
                // vignette / "Tap"), rendered like any other mission type. The grid
                // position seeds the glyph's loop delay so tiles stagger.
                typeTile(type,
                         isSelected: typeChosen && slotType == type,
                         glyphDelay: Double(index) * 0.5,
                         isLocked: isLocked(type)) { selectType(type) }
            }
            if showClearTile {
                typeTile(.none, label: "No Mission", icon: "xmark.circle",
                         isSelected: false) { clearSlot() }
            }
        }
    }

    /// A single pastel mission-type tile (animated glyph + short label). Reused by
    /// the main grid and the fallback grid. `label`/`icon` override the type's
    /// defaults: passing `icon` forces a plain SF Symbol instead of the animated
    /// vignette (used for the "No Mission" clear tile — it's an action, not a
    /// mission). `glyphDelay` staggers the glyph's animation loop per grid slot.
    private func typeTile(_ type: MissionType, label: String? = nil, icon: String? = nil, isSelected: Bool, glyphDelay: Double = 0, isLocked: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.title2)
                        .frame(height: 28)
                } else {
                    MissionTypeGlyph(type: type, accent: isSelected ? accent : Color.primary,
                                     animated: true, delay: glyphDelay)
                }
                Text(label ?? type.shortLabel)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? accent : Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 70)
            .selectableTile(isSelected: isSelected, accent: accent)
            // Locked tiles stay fully visible and tappable — the tap opens the
            // paywall. Hiding them would just look like a missing feature.
            .overlay(alignment: .topTrailing) {
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLocked
                            ? "\(label ?? type.shortLabel), requires Allarise Pro"
                            : (label ?? type.shortLabel))
    }

    /// Whether this mission type is locked. In the free support model every feature is
    /// unlocked (`featuresUnlocked` is always true), so nothing is ever locked — but the
    /// `requiresPro` classification is retained so paid gating can be restored by flipping
    /// one switch in `StoreManager`.
    private func isLocked(_ type: MissionType) -> Bool {
        type.requiresPro && !StoreManager.shared.featuresUnlocked
    }

    private func selectType(_ type: MissionType) {
        // Locked types never reach the draft — the paywall answers instead, so a
        // non-Pro user can't end up with a mission they can't run.
        guard !isLocked(type) else {
            Analytics.shared.log(.paywallShown(source: .missionType))
            showingPaywall = true
            return
        }
        // Mutates ONLY the draft — nothing is committed to the alarm until Save.
        // Load per-type defaults on a genuine change; deliberately here, not an
        // onChange.
        if type == .none {
            // Switch to a Tap mission. Setting only the type preserves the draft's
            // tap fields (a fresh draft already carries the single-tap defaults),
            // so an accidental Math→Tap→Math round-trip is lossless. Mark the Tap
            // choice as explicit (display-only) so a plain single-tap slot still
            // shows as a filled card.
            draft.type = .none
            draft.tapExplicitlyChosen = true
        } else if draft.type != type {
            // A fresh defaultMission() clears tapExplicitlyChosen back to false.
            draft = settings.defaultMission(for: type)
        }
        // Mark that a type has actually been picked: reveals the sections below the
        // grid and highlights the tile. In add mode this also tells Save to append.
        typeChosen = true
    }

    /// Commits the draft on Save: existing slot → write the draft back to its
    /// binding; add mode → append the draft (only if a type was actually picked).
    /// Then writes the drafted grace values, then dismisses. Swipe-down and Cancel
    /// bypass this entirely, so they discard every draft change.
    private func commitDraft() {
        switch target {
        case .slot(let i):
            missionBinding(at: i).wrappedValue = draft
        case .add:
            if typeChosen {
                extraMissions.append(draft)
            }
        }
        useCustomGracePeriod = draftUseCustomGrace
        customGracePeriod = draftCustomGrace
        dismiss()
    }

    /// The distinct "No Mission" action (extra slots only): removes this slot
    /// entirely. Tap slots are real missions, so clearing is an explicit removal —
    /// never a leftover `.none` for compaction to guess at. Slot 1 is the alarm
    /// anchor and has no clear tile.
    private func clearSlot() {
        if let idx = workingIndex, idx >= 1 {
            let extraIndex = idx - 1
            if extraIndex < extraMissions.count {
                extraMissions.remove(at: extraIndex)
            }
        }
        dismiss()
    }

    // MARK: - Fallback selector (duplicate type grid for the HA slot)

    /// Fallback-eligible types: everything playable in-app. Home Assistant is
    /// excluded (an HA fallback for an HA mission is circular) and so is Alert,
    /// which is a notification surface rather than a dismissable mission.
    private var fallbackGridTypes: [MissionType] {
        [.none, .shake, .math, .balanceBall, .blockDrop, .meteor]
    }

    private var fallbackSelectorSection: some View {
        Section {
            let types = fallbackGridTypes
            // Wrap at three columns rather than one-per-type. With four options
            // a single row was fine; at six the tiles were narrow enough that
            // the labels shrank past legibility (`minimumScaleFactor` hid the
            // problem instead of preventing it). Same rule the Settings mission
            // grid uses.
            let columns = Array(repeating: GridItem(.flexible(), spacing: 12),
                                count: types.count <= 4 ? max(1, types.count) : 3)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(types.enumerated()), id: \.element) { index, type in
                    typeTile(type, isSelected: fallbackType == type, glyphDelay: Double(index) * 0.5) { selectFallbackType(type) }
                }
            }
            if let desc = description(for: fallbackType) {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if fallbackType == .math {
                MathProblemPreviewRow(difficulty: haSlotBinding?.wrappedValue.haFallbackMathDifficulty ?? .easy)
            }
        } header: {
            Text("Fallback Mission")
        } footer: {
            Text("Runs instead of Home Assistant if MQTT is unreachable. Tap No Mission to dismiss with a tap.")
                .font(.caption2)
        }
    }

    private func selectFallbackType(_ type: MissionType) {
        haSlotBinding?.wrappedValue.haFallbackMission = type
    }

    // MARK: - Configuration card (real, previewable slot)

    /// One continuous configuration card for the selected slot type: the
    /// difficulty/intensity chip row, the live summary line, the (math-only)
    /// example, the detailed customize controls, and the alarm-level Grace Period
    /// slider at the bottom.
    private var configurationSection: some View {
        Section {
            if let b = slotBinding {
                MissionChipRow(mission: b, accent: accent)
                MissionCustomizeControls(mission: b)
            }

            FallbackGracePeriodSettings(
                gracePeriod: graceBinding,
                fallbackMission: slotBinding?.wrappedValue ?? Mission()
            )
        } header: {
            Text(slotType == .shake ? "Intensity" : "Difficulty")
        }
    }

    // MARK: - Tap (missionless) configuration card

    /// Dismiss-mode config for the Tap slot: a Tap/Hold mode picker (mirroring the
    /// Shake mission's Mode picker) with either a tap-count stepper or a hold-time
    /// stepper, plus the live summary line.
    @ViewBuilder
    private var tapConfigurationSection: some View {
        if let b = slotBinding {
            Section {
                TapDismissControls(mission: b)

                // Multi-tap and hold are REAL missions, so they get the same
                // alarm-level Grace Period control every other mission gets (Auto
                // reflects the new tap/hold formula). A plain single tap has
                // nothing to grace, so it shows no grace group.
                if b.wrappedValue.tapDismissIsMission {
                    FallbackGracePeriodSettings(
                        gracePeriod: graceBinding,
                        fallbackMission: b.wrappedValue
                    )
                }
            } header: {
                Text("Dismiss")
            }
        }
    }

    // MARK: - Fallback configuration card (edits haFallback* fields)

    private var fallbackConfigurationSection: some View {
        Section {
            fallbackChipRow(for: fallbackType)

            fallbackCustomize

            if let m = haSlotBinding {
                FallbackGracePeriodSettings(
                    gracePeriod: m.haFallbackGracePeriod,
                    fallbackMission: m.wrappedValue.dismissFallbackMission
                )
            }
        } header: {
            Text(fallbackType == .shake ? "Intensity" : "Difficulty")
        }
    }

    /// One-line summary of the fallback's difficulty/customize settings, built
    /// from the HA slot's `haFallback*` fields.
    private var fallbackSummary: String? {
        guard let m = haSlotBinding?.wrappedValue else { return nil }
        switch m.haFallbackMission {
        case .shake:
            switch m.haFallbackShakeMode {
            case .duration:
                return "Shake · \(m.haFallbackShakeDuration)s · \(m.haFallbackShakeIntensity.rawValue)"
            case .count:
                return "Shake · \(m.haFallbackShakeCount) shakes · \(m.haFallbackShakeIntensity.rawValue)"
            }
        case .math:
            return "\(m.haFallbackMathProblemCount) Problem\(m.haFallbackMathProblemCount == 1 ? "" : "s") · \(m.haFallbackMathDifficulty.displayLabel)"
        case .balanceBall:
            return "Balance · \(m.haFallbackBalanceDifficulty.rawValue) · \(Int(m.haFallbackBalanceDifficulty.holdDuration))s hold"
        default:
            return nil
        }
    }

    /// The mission handed to Try It Out — the built fallback for the HA slot,
    /// otherwise the slot itself.
    private var previewMission: Mission {
        if slotType == .homeAssistant {
            return haSlotBinding?.wrappedValue.dismissFallbackMission ?? Mission()
        }
        return slotBinding?.wrappedValue ?? Mission()
    }

    // MARK: - Difficulty / intensity chips (fallback only)

    /// A single edge-to-edge row of equal-width chips for the HA slot's
    /// fallback mission, editing the `haFallback*` fields. The real slot's
    /// chips are the shared MissionChipRow.
    @ViewBuilder
    private func fallbackChipRow(for type: MissionType) -> some View {
        HStack(spacing: 8) {
            switch type {
            case .shake:
                let current: ShakeIntensity = haSlotBinding?.wrappedValue.haFallbackShakeIntensity ?? .medium
                ForEach(ShakeIntensity.allCases, id: \.self) { intensity in
                    chip(intensity.rawValue, selected: current == intensity) {
                        haSlotBinding?.wrappedValue.haFallbackShakeIntensity = intensity
                    }
                }
            case .math:
                let current: MathDifficulty = haSlotBinding?.wrappedValue.haFallbackMathDifficulty ?? .easy
                ForEach(MathDifficulty.allCases, id: \.self) { difficulty in
                    chip(difficulty.displayLabel, selected: current == difficulty) {
                        haSlotBinding?.wrappedValue.haFallbackMathDifficulty = difficulty
                    }
                }
            case .balanceBall:
                let current: BalanceDifficulty = haSlotBinding?.wrappedValue.haFallbackBalanceDifficulty ?? .medium
                ForEach(BalanceDifficulty.allCases, id: \.self) { difficulty in
                    chip(difficulty.rawValue, selected: current == difficulty) {
                        haSlotBinding?.wrappedValue.haFallbackBalanceDifficulty = difficulty
                    }
                }
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    /// An equal-width chip that fills its share of the row and centers its label.
    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(selected ? accent : Color.primary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 54)
                .selectableTile(isSelected: selected, accent: accent, cornerRadius: 12)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Grace period (alarm-level, shared by all slots)

    /// Bridges the alarm's two grace-state bindings into the single 0-means-Auto
    /// slider value the UI shows. 0 → Auto (no custom override).
    private var graceBinding: Binding<Double> {
        Binding(
            get: { draftUseCustomGrace ? draftCustomGrace : 0 },
            set: { newValue in
                if newValue <= 0 {
                    draftUseCustomGrace = false
                    draftCustomGrace = 0
                } else {
                    draftUseCustomGrace = true
                    draftCustomGrace = newValue
                }
            }
        )
    }

    // MARK: - Try It Out (pinned at the bottom)

    private func tryItOutSection(_ preview: Mission) -> some View {
        Section {
            ProminentPreviewButton(accent: accent) {
                previewRequest = MissionPreviewRequest(mission: preview)
            }
        }
    }

    // MARK: - Fallback customize (edits haFallback* fields)

    @ViewBuilder
    private var fallbackCustomize: some View {
        if let m = haSlotBinding {
            switch m.wrappedValue.haFallbackMission {
            case .shake:
                Picker("Mode", selection: m.haFallbackShakeMode) {
                    ForEach(ShakeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if m.wrappedValue.haFallbackShakeMode == .duration {
                    Stepper("Duration: \(m.wrappedValue.haFallbackShakeDuration)s", value: m.haFallbackShakeDuration, in: 1...30)
                } else {
                    Stepper("Count: \(m.wrappedValue.haFallbackShakeCount)", value: m.haFallbackShakeCount, in: 5...100, step: 5)
                }
            case .math:
                Stepper("Problems: \(m.wrappedValue.haFallbackMathProblemCount)", value: m.haFallbackMathProblemCount, in: 1...10)
            case .balanceBall:
                LabeledContent("Hold time", value: "\(Int(m.wrappedValue.haFallbackBalanceDifficulty.holdDuration))s")
            default:
                EmptyView()
            }
        }
    }

}
