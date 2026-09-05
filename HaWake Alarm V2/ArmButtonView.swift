//
//  ArmButtonView.swift
//  HaWake Alarm V2
//
//  Home Assistant widget for the home screen.
//  Shows custom commands and optional arm/disarm control.
//  HA owns the arm state. App sends commands and displays HA's confirmed state.
//

import SwiftUI

extension Notification.Name {
    static let widgetCommandExecuted = Notification.Name("widgetCommandExecuted")
}

struct ArmButtonView: View {
    let settings: DeviceSettings
    let mqttManager: HAIntegrationRouter
    @Environment(\.colorScheme) private var colorScheme
    
    // MARK: - State
    
    /// nil = no state received yet (offline or waiting for HA), true = armed, false = disarmed
    @State private var armState: Bool?
    @State private var holdProgress: CGFloat = 0
    @State private var isHolding = false
    @State private var holdCompleted = false
    @State private var displayLink: DisplayLinkTimer?
    @State private var isExpanded = false
    @State private var showCommandEditor = false
    @State private var executedCommandIcon: String?
    /// Color to tint the confirmation icon — the fired command's own icon color,
    /// so the flash reads as "that command ran" rather than a generic green.
    @State private var executedCommandColor: Color?
    @State private var pendingCommand: MQTTCommand?
    @State private var showConfirmAlert = false
    /// Where `pendingCommand` was triggered from — the confirm alert fires it
    /// later, by which time the originating gesture/row is out of scope.
    @State private var pendingSurface: CommandSurface = .widgetList

    // MARK: - Appearance
    
    private var colors: HomeColorCustomization {
        colorScheme == .dark ? settings.homeColorCustomizationDark : settings.homeColorCustomization
    }

    /// Base color for the arm/disarm chip — its label, its wash, the solid armed
    /// fill, and the `HoldPressStyle` progress fill. Routed through
    /// `settings.armAccent(for:)` so the per-theme accent override reaches it
    /// (al-4gz); with no override set this is `colors.resolvedArmButtonColor`,
    /// exactly as before. Each site keeps its own opacity, so the press retains
    /// its layered depth rather than flattening to one tone.
    private var armAccent: Color {
        settings.armAccent(for: colorScheme)
    }


    /// Icon color adapts to mode: alarm icon color when alarm on, HA widget icon color when alarm off
    private var resolvedIconColor: Color {
        alarmControlEnabled ? colors.resolvedArmButtonIconColor : colors.resolvedHassWidgetIconColor
    }
    
    /// Text color adapts to mode
    private var resolvedTextColor: Color {
        alarmControlEnabled ? colors.resolvedArmButtonTextColor : colors.resolvedHassWidgetTextColor
    }
    
    private var scale: CGFloat {
        settings.biggerWidget ? 1.2 : 1.0
    }
    
    private var isArmed: Bool {
        armState == true
    }
    
    /// Whether alarm control (arm/disarm) is enabled
    private var alarmControlEnabled: Bool {
        settings.hassWidgetAlarmEnabled
    }
    
    /// Button is interactive only when MQTT is connected and we have a state from HA
    private var isInteractive: Bool {
        alarmControlEnabled && mqttManager.isConnected && armState != nil
    }
    
    /// True when MQTT is disconnected or we haven't received state yet
    private var isOffline: Bool {
        !mqttManager.isConnected || (alarmControlEnabled && armState == nil)
    }
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            // Main banner row
            HStack {
                // Left side: icon + label — tap to expand commands
                HStack(spacing: 12 * scale) {
                    Image(systemName: executedCommandIcon ?? iconName)
                        .font(.system(size: 22 * scale, weight: .semibold))
                        .foregroundStyle(executedCommandIcon != nil
                            ? (executedCommandColor ?? resolvedIconColor)
                            : resolvedIconColor)
                        .contentTransition(.symbolEffect(.replace))
                    
                    Text(labelText)
                        .font(.system(size: 16 * scale, weight: .semibold))
                        .foregroundStyle(resolvedTextColor)
                    
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if let cmdID = settings.widgetDoubleTapCommandID,
                       let command = settings.mqttCommands.first(where: { $0.id == cmdID }) {
                        fireGestureCommand(command)
                    }
                }
                .onTapGesture(count: 1) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isExpanded.toggle()
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 30)
                        .onEnded { value in
                            let tx = value.translation.width
                            if tx < -60, let cmdID = settings.widgetSwipeLeftCommandID,
                               let command = settings.mqttCommands.first(where: { $0.id == cmdID }) {
                                fireGestureCommand(command)
                            } else if tx > 60, let cmdID = settings.widgetSwipeRightCommandID,
                                      let command = settings.mqttCommands.first(where: { $0.id == cmdID }) {
                                fireGestureCommand(command)
                            }
                        }
                )
                
                // Right side: hold-to-arm/disarm button (skip button style)
                if isInteractive {
                    armDisarmButton
                }
            }
            .padding(.vertical, 16 * scale)
            .padding(.leading, 16 * scale)
            .padding(.trailing, 12 * scale)
            
            // Expanded command list
            if isExpanded {
                Divider()
                    .padding(.horizontal, 16 * scale)
                
                expandedCommands
            }
        }
        .background {
            ZStack {
                if !settings.homeWallpaperEnabled {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
                } else if clearDimming > 0 {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.black.opacity(clearDimming))
                }
            }
        }
        .glassEffect(resolvedGlassVariant, in: .rect(cornerRadius: 16))
        .overlay {
            if settings.homeWallpaperEnabled {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.4), lineWidth: 0.5)
            }
        }
        .opacity(isOffline ? 0.5 : 1.0)
        .sheet(isPresented: $showCommandEditor) {
            NavigationStack {
                CommandWidgetSettingsView(settings: settings)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showCommandEditor = false }
                        }
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ArmStateChanged"))) { notification in
            handleArmStateNotification(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .widgetCommandExecuted)) { notification in
            if let icon = notification.userInfo?["icon"] as? String {
                let color: Color?
                if let r = notification.userInfo?["iconColorRed"] as? Double,
                   let g = notification.userInfo?["iconColorGreen"] as? Double,
                   let b = notification.userInfo?["iconColorBlue"] as? Double {
                    color = Color(red: r, green: g, blue: b)
                } else {
                    color = nil
                }
                withAnimation {
                    executedCommandIcon = icon
                    executedCommandColor = color
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation {
                        executedCommandIcon = nil
                        executedCommandColor = nil
                    }
                }
            }
        }
        .onChange(of: settings.armZone) { _, _ in
            // Zone changed — reset so we don't show stale state from the previous zone.
            armState = nil
            settings.cachedArmState = false
        }
        .onChange(of: mqttManager.isConnected) { _, connected in
            if connected {
                // Pre-populate from cache so the button is interactive immediately.
                // HA's authoritative retained state will override this as soon as it arrives.
                if armState == nil {
                    armState = settings.cachedArmState
                }
            } else {
                armState = nil
                holdProgress = 0
                cancelHold()
            }
        }
        .onAppear {
            // Seed arm state from cache when MQTT is already connected. The view
            // can be recreated (e.g. a light/dark switch via .id) while the
            // connection stays up — onChange(isConnected) won't fire then, so
            // without this the widget would be stuck showing "Connecting…".
            if armState == nil && mqttManager.isConnected {
                armState = settings.cachedArmState
            }
        }
        .alert("Confirm Command", isPresented: $showConfirmAlert, presenting: pendingCommand) { command in
            Button("Run", role: .destructive) {
                executeCommand(command, surface: pendingSurface)
            }
            Button("Cancel", role: .cancel) {}
        } message: { command in
            Text("Run \"\(command.name)\"?")
        }
    }
    
    // MARK: - Arm/Disarm Button (skip button pattern)
    
    private var armDisarmButton: some View {
        // Use invisible spaces (Unicode thin spaces \u{2009}) to pad "Arm" to match "Disarm" width
        let armLabel = "\u{2009}\u{2009}Arm\u{2009}\u{2009}"
        let disarmLabel = "Disarm"
        
        return HStack(spacing: 4) {
            // The padlock shows the CURRENT state, not the action: armed means the
            // lock is closed, so "Disarm" carries a locked padlock and "Arm"
            // carries an open one. It used to be the other way around, which read
            // as a preview of the result and inverted the status at a glance.
            Image(systemName: isArmed ? "lock.fill" : "lock.open.fill")
                .font(.caption2)
            Text(isArmed ? disarmLabel : armLabel)
                .font(.caption2)
                .fontWeight(.medium)
        }
        // Armed is a SOLID accent chip with a white label. The armed state used to
        // be the same accent-on-grey as disarmed, just a slightly denser wash, so
        // the most important state the widget can show read as a dimmer version of
        // the other one. Disarmed keeps its existing subtle treatment.
        .foregroundStyle(isArmed ? Color.white : armAccent)
        .padding(.horizontal, 8)
        .padding(.vertical, 14)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                RoundedRectangle(cornerRadius: 8)
                    .fill(isArmed
                          ? armAccent
                          : armAccent.opacity(0.12))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // Tactile hold-to-arm/disarm press.
        .holdPress(progress: holdProgress, isHolding: isHolding,
                   accent: armAccent, cornerRadius: 8)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isHolding && !holdCompleted && isInteractive {
                        startHold()
                    }
                }
                .onEnded { _ in
                    holdCompleted = false
                    if isHolding {
                        endHold(completed: false)
                    }
                }
        )
        .scaleEffect(scale, anchor: .trailing)
    }
    
    // MARK: - Expanded Commands
    
    /// Commands visible in the expanded list (filtered by showInList toggle)
    private var visibleCommands: [MQTTCommand] {
        settings.mqttCommands.filter { $0.showInList }
    }
    
    private var expandedCommands: some View {
        VStack(spacing: 0) {
            ForEach(visibleCommands) { command in
                Button {
                    requestCommand(command, surface: .widgetList)
                } label: {
                    HStack(spacing: 12 * scale) {
                        Image(systemName: command.icon)
                            .font(.system(size: 18 * scale))
                            .foregroundStyle(command.iconColor)
                            .frame(width: 26 * scale)
                        
                        Text(command.name.isEmpty ? "Untitled" : command.name)
                            .font(.system(size: 16 * scale))
                            .foregroundStyle(command.name.isEmpty
                                ? resolvedTextColor.opacity(0.4)
                                : resolvedTextColor)
                        
                        Spacer()
                        
                        if alarmControlEnabled && command.armAction != .none {
                            Text(command.armAction.label)
                                .font(.system(size: 12 * scale))
                                .foregroundStyle(resolvedTextColor.opacity(0.4))
                        }
                    }
                    .padding(.horizontal, 16 * scale)
                    .padding(.vertical, 14 * scale)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(command.name.isEmpty)
            }
            
            // Edit commands link
            Divider()
                .padding(.horizontal, 16 * scale)
            
            Button {
                showCommandEditor = true
            } label: {
                HStack(spacing: 12 * scale) {
                    Image(systemName: "pencil")
                        .font(.system(size: 18 * scale))
                        .foregroundStyle(resolvedTextColor.opacity(0.5))
                        .frame(width: 26 * scale)
                    
                    Text("Edit Commands")
                        .font(.system(size: 16 * scale))
                        .foregroundStyle(resolvedTextColor.opacity(0.5))
                    
                    Spacer()
                }
                .padding(.horizontal, 16 * scale)
                .padding(.vertical, 14 * scale)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 4 * scale)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
    
    // MARK: - Command Execution
    
    /// Gates command execution behind optional confirmation alert
    private func requestCommand(_ command: MQTTCommand, surface: CommandSurface) {
        if settings.confirmCommandsEnabled {
            pendingCommand = command
            pendingSurface = surface
            showConfirmAlert = true
        } else {
            executeCommand(command, surface: surface)
        }
    }

    private func executeCommand(_ command: MQTTCommand, surface: CommandSurface) {
        // Only send if connected
        guard mqttManager.isConnected else { return }

        Analytics.shared.log(.commandFired(kind: command.sourceKind, surface: surface))

        // Publish command name as sensor
        if !command.name.isEmpty {
            mqttManager.publishArmCustomCommand(command.name, settings: settings)
        }
        
        // Execute arm action (only when alarm control is enabled)
        if alarmControlEnabled {
            switch command.armAction {
            case .none:
                break
            case .arm:
                mqttManager.requestArmStateChange(true, settings: settings)
            case .disarm:
                mqttManager.requestArmStateChange(false, settings: settings)
            case .toggle:
                let newState = !(armState ?? false)
                mqttManager.requestArmStateChange(newState, settings: settings)
            }
        }
        
        // Briefly replace the house icon with the command's own icon and color
        withAnimation {
            executedCommandIcon = command.icon
            executedCommandColor = command.iconColor
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                executedCommandIcon = nil
                executedCommandColor = nil
            }
        }
    }
    
    // MARK: - Gesture Commands
    
    private func fireGestureCommand(_ command: MQTTCommand) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        requestCommand(command, surface: .widgetGesture)
    }
    
    // MARK: - Visual Properties
    
    private var iconName: String {
        return "house.fill"
    }
    
    private var labelText: String {
        if !alarmControlEnabled {
            return mqttManager.isConnected ? "Home Assistant" : "Offline"
        }
        if !mqttManager.isConnected {

            return "Offline"
        }
        if armState == nil {
            return "Connecting..."
        }
        if isHolding {
            return isArmed ? "Disarming..." : "Arming..."
        }
        // Show the zone name — armed/disarmed state is communicated via the red outline.
        let zone = settings.armZone.trimmingCharacters(in: .whitespaces)
        return zone.isEmpty ? "Home" : zone
    }
    
    // MARK: - Glass
    
    // The command widget reads the same `homeGlass*` settings as the alarm rows
    // so it always matches the active theme. The separate `widgetGlass*` settings
    // are intentionally no longer consulted here.
    private var resolvedGlassVariant: Glass {
        guard settings.homeWallpaperEnabled else { return .identity }
        let isDark = colorScheme == .dark
        let variant = isDark ? settings.homeDarkGlassVariant : settings.homeGlassVariant
        switch variant {
        case 1: return .clear
        case 2:
            let r = isDark ? settings.homeDarkGlassTintRed : settings.homeGlassTintRed
            let g = isDark ? settings.homeDarkGlassTintGreen : settings.homeGlassTintGreen
            let b = isDark ? settings.homeDarkGlassTintBlue : settings.homeGlassTintBlue
            let opacity = isDark ? settings.homeDarkGlassTintOpacity : settings.homeGlassTintOpacity
            return .regular.tint(Color(red: r, green: g, blue: b).opacity(opacity))
        default: return .regular
        }
    }

    private var clearDimming: Double {
        guard settings.homeWallpaperEnabled else { return 0 }
        let isDark = colorScheme == .dark
        let variant = isDark ? settings.homeDarkGlassVariant : settings.homeGlassVariant
        guard variant == 1 else { return 0 }
        return isDark ? settings.homeDarkGlassClearDimming : settings.homeGlassClearDimming
    }
    
    // MARK: - Hold Logic
    
    private func startHold() {
        isHolding = true
        let totalDuration = settings.armButtonHoldDuration
        
        // Wall clock, not tick count (al-hjb): DisplayLinkTimer's delta is the
        // nominal frame period, so summing it measures frames delivered — every
        // dropped frame lengthened the hold. Same fix as the skip hold (al-lwz).
        let started = Date()
        if isArmed {
            // Disarming: gradient drains backward from full to empty
            holdProgress = 1.0
            displayLink = DisplayLinkTimer { _ in
                holdProgress = max(1.0 - Date().timeIntervalSince(started) / totalDuration, 0)
                if holdProgress <= 0 {
                    completeHold()
                }
            }
        } else {
            // Arming: gradient fills forward from empty to full
            holdProgress = 0
            displayLink = DisplayLinkTimer { _ in
                holdProgress = min(Date().timeIntervalSince(started) / totalDuration, 1.0)
                if holdProgress >= 1.0 {
                    completeHold()
                }
            }
        }
        displayLink?.start()
    }
    
    private func endHold(completed: Bool) {
        displayLink?.stop()
        displayLink = nil
        
        guard !completed else {
            isHolding = false
            return
        }
        
        let wasDisarming = isArmed
        isHolding = false
        
        // Rubber band snap-back (0.1s)
        let reverseDuration: Double = 0.1
        let savedProgress = holdProgress
        
        if wasDisarming {
            // Disarming was interrupted — snap back toward 1.0 (full border)
            guard savedProgress < 0.999 else {
                holdProgress = 0  // will show persistent armed border
                return
            }
            let gap = 1.0 - savedProgress
            displayLink = DisplayLinkTimer { deltaTime in
                holdProgress += deltaTime / reverseDuration * gap
                if holdProgress >= 1.0 {
                    holdProgress = 0  // reset — persistent armed border takes over
                    displayLink?.stop()
                    displayLink = nil
                }
            }
        } else {
            // Arming was interrupted — snap back toward 0
            guard savedProgress > 0.001 else {
                holdProgress = 0
                return
            }
            displayLink = DisplayLinkTimer { deltaTime in
                holdProgress -= deltaTime / reverseDuration * savedProgress
                if holdProgress <= 0 {
                    holdProgress = 0
                    displayLink?.stop()
                    displayLink = nil
                }
            }
        }
        displayLink?.start()
    }
    
    private func completeHold() {
        displayLink?.stop()
        displayLink = nil
        isHolding = false
        holdCompleted = true
        holdProgress = 0
        
        let newArmed = !isArmed
        // Optimistic update — update UI immediately so the button feels responsive.
        // HA will confirm (or correct) via a retained publish to arm/state.
        withAnimation(.easeInOut(duration: 0.3)) {
            armState = newArmed
        }
        mqttManager.requestArmStateChange(newArmed, settings: settings)
    }
    
    private func cancelHold() {
        displayLink?.stop()
        displayLink = nil
        isHolding = false
    }
    
    // MARK: - HA State Handling
    
    private func handleArmStateNotification(_ notification: Notification) {
        if let armed = notification.userInfo?["armed"] as? Bool {
            withAnimation(.easeInOut(duration: 0.3)) {
                armState = armed
            }
            // Persist so we can pre-populate on next connect (bootstrapping HACS entity creation)
            settings.cachedArmState = armed
            holdProgress = 0
        }
    }
}

// MARK: - DisplayLinkTimer

/// CADisplayLink wrapper for smooth 120Hz animation (same as AlarmListView/ActiveAlarmView).
private class DisplayLinkTimer {
    private var displayLink: CADisplayLink?
    private var onTick: ((Double) -> Void)?
    
    init(onTick: @escaping (Double) -> Void) {
        self.onTick = onTick
    }
    
    func start() {
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func tick(_ link: CADisplayLink) {
        let delta = link.targetTimestamp - link.timestamp
        onTick?(delta)
    }
    
    deinit {
        stop()
    }
}
