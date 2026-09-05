//
//  CommandLibrary.swift
//  HaWake Alarm V2
//
//  The shared vocabulary behind the unified command-management system: where a
//  command can be ASSIGNED, what SOURCE it came from, WHO is using it, and how to
//  delete one without leaving a dangling id behind.
//
//  Deliberately persistence-free. `MQTTCommand` keeps its exact stored shape (and
//  its ids), so nothing here needs a migration:
//    • `actionURL == nil`              → Home Assistant
//    • `actionURL` scheme "shortcuts"  → Shortcut
//    • any other non-nil `actionURL`   → Link
//  The source is DERIVED on read — see `MQTTCommand.sourceKind`.
//

import SwiftData
import SwiftUI

// MARK: - Source kind

/// Where a command's action goes when it fires. Derived from the stored
/// `actionURL`, never persisted separately.
enum CommandSourceKind: String, CaseIterable, Identifiable {
    case homeAssistant
    case shortcut
    case link

    var id: String { rawValue }

    /// User-facing name. `.link` presents AS "Shortcut": the UI only ever offers
    /// two kinds of command (the picker's two filter tabs, the form's
    /// "Home Assistant" / "Shortcut / Link" tabs), so surfacing a third word in
    /// badges leaked an internal distinction the user was never asked to make.
    /// The cases stay separate because the derivation is genuinely different —
    /// only the presentation is shared.
    var label: String {
        switch self {
        case .homeAssistant:     return "Home Assistant"
        case .shortcut, .link:   return "Shortcut"
        }
    }

    /// SF Symbol standing in for the source. Deliberately generic house /
    /// stacked-layers glyphs — never a third-party logo. `.link` shares the
    /// shortcut glyph for the same reason it shares the label.
    var glyph: String {
        switch self {
        case .homeAssistant:     return "house.fill"
        case .shortcut, .link:   return "square.stack.3d.up.fill"
        }
    }

    /// True when this source stores a URL in `actionURL`.
    var isURL: Bool { self != .homeAssistant }
}

extension MQTTCommand {
    /// The command's source, derived from `actionURL` (no stored field, no
    /// migration). Home Assistant is the default for legacy commands, which is
    /// exactly what they were.
    var sourceKind: CommandSourceKind {
        guard let raw = resolvedActionURL else { return .homeAssistant }
        if URL(string: raw)?.scheme?.lowercased() == "shortcuts" { return .shortcut }
        return .link
    }

    /// Name as shown in every list/badge — never blank.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}

// MARK: - Source badge

/// The compact source marker shown wherever a command appears as ASSIGNED —
/// notes slots, swipe rows, the picker, the form's live preview, the global list.
struct CommandSourceBadge: View {
    let kind: CommandSourceKind
    /// Glyph-only (for tight spots like a 48×48 command square's corner).
    var showsLabel: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.glyph)
                .font(.caption2)
            if showsLabel {
                Text(kind.label)
                    .font(.caption2)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, showsLabel ? 6 : 4)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
        .accessibilityLabel(kind.label)
    }
}

// MARK: - Assignment destinations

/// Every place a command can be assigned. Drives the picker's context banner
/// ("Will assign to Button 2") and the deletion usage report.
enum CommandAssignmentDestination: Identifiable, Hashable {
    /// One of the four after-alarm Notes command buttons (0-based slot).
    case noteSlot(Int)
    case alarmSwipeLeft
    case alarmSwipeRight
    case widgetSwipeLeft
    case widgetSwipeRight
    case widgetDoubleTap

    var id: String {
        switch self {
        case .noteSlot(let slot):  return "noteSlot-\(slot)"
        case .alarmSwipeLeft:      return "alarmSwipeLeft"
        case .alarmSwipeRight:     return "alarmSwipeRight"
        case .widgetSwipeLeft:     return "widgetSwipeLeft"
        case .widgetSwipeRight:    return "widgetSwipeRight"
        case .widgetDoubleTap:     return "widgetDoubleTap"
        }
    }

    /// Short human label — "Button 2", "Swipe Left", "Double Tap".
    var label: String {
        switch self {
        case .noteSlot(let slot):                     return "Button \(slot + 1)"
        case .alarmSwipeLeft, .widgetSwipeLeft:       return "Swipe Left"
        case .alarmSwipeRight, .widgetSwipeRight:     return "Swipe Right"
        case .widgetDoubleTap:                        return "Double Tap"
        }
    }

    /// True when the destination belongs to the home-screen command widget
    /// rather than an alarm.
    var isWidget: Bool {
        switch self {
        case .widgetSwipeLeft, .widgetSwipeRight, .widgetDoubleTap: return true
        default: return false
        }
    }
}

// MARK: - Usage resolution

/// One resolved place a command is currently assigned.
struct CommandUsage: Equatable, Identifiable {
    let destination: CommandAssignmentDestination
    /// The owning alarm's label; nil when the usage lives on the home widget.
    let alarmLabel: String?

    var id: String { "\(destination.id)|\(alarmLabel ?? "")" }

    /// "Button 1 in Morning Alarm" / "Swipe Left on the Home Assistant widget".
    var phrase: String {
        if let alarmLabel, !alarmLabel.isEmpty {
            return "\(destination.label) in \(alarmLabel)"
        }
        return "\(destination.label) on the Home Assistant widget"
    }
}

/// Finds every persisted reference to a command id. Kept free of `DeviceSettings`
/// in its core overload so it is directly testable.
enum CommandUsageResolver {

    /// Core resolution — plain inputs, no singletons.
    static func usages(of id: UUID,
                       widgetSwipeLeft: UUID?,
                       widgetSwipeRight: UUID?,
                       widgetDoubleTap: UUID?,
                       alarms: [Alarm]) -> [CommandUsage] {
        var found: [CommandUsage] = []
        let idString = id.uuidString

        if widgetSwipeLeft == id  { found.append(CommandUsage(destination: .widgetSwipeLeft, alarmLabel: nil)) }
        if widgetSwipeRight == id { found.append(CommandUsage(destination: .widgetSwipeRight, alarmLabel: nil)) }
        if widgetDoubleTap == id  { found.append(CommandUsage(destination: .widgetDoubleTap, alarmLabel: nil)) }

        for alarm in alarms {
            let label = alarm.label
            if matches(alarm.swipeLeftCommandID, idString) {
                found.append(CommandUsage(destination: .alarmSwipeLeft, alarmLabel: label))
            }
            if matches(alarm.swipeRightCommandID, idString) {
                found.append(CommandUsage(destination: .alarmSwipeRight, alarmLabel: label))
            }
            let slots = [alarm.alarmScreenCommandID1, alarm.alarmScreenCommandID2,
                         alarm.alarmScreenCommandID3, alarm.alarmScreenCommandID4]
            for (slot, stored) in slots.enumerated() where matches(stored, idString) {
                found.append(CommandUsage(destination: .noteSlot(slot), alarmLabel: label))
            }
        }
        return found
    }

    /// Convenience over live settings.
    static func usages(of id: UUID, settings: DeviceSettings, alarms: [Alarm]) -> [CommandUsage] {
        usages(of: id,
               widgetSwipeLeft: settings.widgetSwipeLeftCommandID,
               widgetSwipeRight: settings.widgetSwipeRightCommandID,
               widgetDoubleTap: settings.widgetDoubleTapCommandID,
               alarms: alarms)
    }

    /// "Button 1 in Morning Alarm and Swipe Right in Weekday Alarm"
    static func summary(_ usages: [CommandUsage]) -> String {
        let phrases = usages.map(\.phrase)
        switch phrases.count {
        case 0:  return ""
        case 1:  return phrases[0]
        case 2:  return "\(phrases[0]) and \(phrases[1])"
        default: return phrases.dropLast().joined(separator: ", ") + ", and \(phrases[phrases.count - 1])"
        }
    }

    /// The full confirmation body shown before a destructive delete.
    static func deletionMessage(for command: MQTTCommand, usages: [CommandUsage]) -> String {
        guard !usages.isEmpty else {
            return "This command isn't assigned anywhere. Deleting it can't be undone."
        }
        let tail: String
        switch usages.count {
        case 1:  tail = "Deleting it will clear that assignment."
        case 2:  tail = "Deleting it will clear both assignments."
        default: tail = "Deleting it will clear all \(usages.count) assignments."
        }
        return "This command is assigned to \(summary(usages)). \(tail)"
    }

    private static func matches(_ stored: String?, _ idString: String) -> Bool {
        guard let stored else { return false }
        return stored.caseInsensitiveCompare(idString) == .orderedSame
    }
}

// MARK: - Deletion

extension Notification.Name {
    /// Broadcast after a command is removed from the library so any OPEN editor
    /// holding an unsaved draft assignment (alarm editor swipe drafts, the
    /// After-Alarm sheet's note slots, the Notes editor's slots) can clear it.
    /// `userInfo["id"]` is the deleted `UUID`.
    static let mqttCommandDeleted = Notification.Name("mqttCommandDeleted")
}

/// Removes a command from the library AND every persisted reference to it, so a
/// delete can never leave a dangling id behind. Command ORDER is otherwise
/// untouched, and no other command's id changes.
enum CommandDeletionCoordinator {

    /// Deletes `id` everywhere. Returns the usages that were cleared.
    @discardableResult
    static func delete(_ id: UUID,
                       settings: DeviceSettings,
                       alarms: [Alarm],
                       modelContext: ModelContext?) -> [CommandUsage] {
        let cleared = CommandUsageResolver.usages(of: id, settings: settings, alarms: alarms)

        // 1 — the library itself.
        settings.mqttCommands.removeAll { $0.id == id }

        // 2 — widget gestures.
        if settings.widgetSwipeLeftCommandID == id  { settings.widgetSwipeLeftCommandID = nil }
        if settings.widgetSwipeRightCommandID == id { settings.widgetSwipeRightCommandID = nil }
        if settings.widgetDoubleTapCommandID == id  { settings.widgetDoubleTapCommandID = nil }

        // 3 — every alarm's swipe + notes slots.
        var touchedAlarms = false
        let idString = id.uuidString
        for alarm in alarms {
            if clear(&alarm.swipeLeftCommandID, idString)      { touchedAlarms = true }
            if clear(&alarm.swipeRightCommandID, idString)     { touchedAlarms = true }
            if clear(&alarm.alarmScreenCommandID1, idString)   { touchedAlarms = true }
            if clear(&alarm.alarmScreenCommandID2, idString)   { touchedAlarms = true }
            if clear(&alarm.alarmScreenCommandID3, idString)   { touchedAlarms = true }
            if clear(&alarm.alarmScreenCommandID4, idString)   { touchedAlarms = true }
        }
        if touchedAlarms, let modelContext {
            do { try modelContext.save() }
            catch { AppLogger.shared.log("Command delete: failed to save cleared alarm references: \(error)", category: .alarm) }
        }

        // 4 — unsaved drafts in any open editor.
        NotificationCenter.default.post(name: .mqttCommandDeleted, object: nil, userInfo: ["id": id])

        // Logged here rather than at the call sites: this is the ONE deletion
        // path, so every entry point is covered without duplicating the event.
        Task { @MainActor in Analytics.shared.log(.commandDeleted) }

        return cleared
    }

    /// Nils out `field` when it holds `idString`. Returns whether it changed.
    private static func clear(_ field: inout String?, _ idString: String) -> Bool {
        guard let current = field, current.caseInsensitiveCompare(idString) == .orderedSame else { return false }
        field = nil
        return true
    }

    /// Clears any slot of a `[String?]` draft that points at the deleted command.
    /// Used by the editors that own unsaved draft assignments.
    static func clearDraftSlots(_ slots: inout [String?], deleted id: UUID) {
        let idString = id.uuidString
        for index in slots.indices {
            if let stored = slots[index], stored.caseInsensitiveCompare(idString) == .orderedSame {
                slots[index] = nil
            }
        }
    }
}

// MARK: - Assignment row

/// The shared "this destination currently points at X" row used by the swipe
/// sections and the widget gesture config. Tapping it opens `CommandPickerSheet`
/// — which the HOST presents from a stable root, never from this row.
struct CommandAssignmentRow: View {
    let destination: CommandAssignmentDestination
    let command: MQTTCommand?
    /// Leading glyph + tint describing the destination itself (an arrow, a hand).
    var leadingGlyph: String
    var leadingTint: Color
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: leadingGlyph)
                    .foregroundStyle(leadingTint)
                Text(destination.label)
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 8)
                if let command {
                    Image(systemName: command.icon)
                        .foregroundStyle(command.iconColor)
                    Text(command.displayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    CommandSourceBadge(kind: command.sourceKind, showsLabel: false)
                } else {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(command == nil
            ? "\(destination.label), unassigned"
            : "\(destination.label), \(command!.displayName), \(command!.sourceKind.label)")
    }
}
