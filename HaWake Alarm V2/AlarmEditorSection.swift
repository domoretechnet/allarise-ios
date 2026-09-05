//
//  AlarmEditorSection.swift
//  HaWake Alarm V2
//
//  Identifies which collapsible section of the alarm editor is expanded.
//  Each editor owns one optional value and passes a binding into every
//  section view, so expanding one section collapses the others back to
//  their summary cards (accordion behavior). Views used outside the
//  editor default the binding to .constant(nil) and behave as before.
//

import SwiftUI

enum AlarmEditorSection {
    case sound
    case mission
    case gracePeriod
    case snooze
    case skipAlarm
    case fallbackMission
    case swipeCommands
}

#if DEBUG
extension AlarmEditorSection {
    /// DEBUG harness hook: the section named by `-editorExpand <name>`, so a
    /// screenshot run can open an accordion no automated tap can reach.
    /// Never set in the shipping app.
    ///
    ///   simctl launch booted <bundle-id> -alarmEditorDebug -editorExpand swipe
    static var debugPreexpanded: AlarmEditorSection? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-editorExpand"),
              let name = args.dropFirst(idx + 1).first else { return nil }
        switch name {
        case "sound":           return .sound
        case "mission":         return .mission
        case "gracePeriod":     return .gracePeriod
        case "snooze":          return .snooze
        case "skipAlarm":       return .skipAlarm
        case "fallbackMission": return .fallbackMission
        case "swipe":           return .swipeCommands
        default:                return nil
        }
    }
}
#endif
