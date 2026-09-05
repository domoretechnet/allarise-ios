//
//  MQTTCommandEditorView.swift
//  HaWake Alarm V2
//
//  RETIRED. The command library it used to implement now lives in
//  `CommandLibraryView` (HaWake Alarm V2/CommandLibraryView.swift), which every
//  entry point — the picker's "Manage Commands" link, the Notes editor's
//  "Manage" button, the Command Widget page's own link — points at directly.
//  (Settings no longer carries its own Commands row; the contextual links cover
//  every case.)
//
//  Kept as a thin forwarder rather than deleted: this is a repo-root file
//  individually referenced in project.pbxproj, so removing it needs pbxproj
//  surgery. Duplicating the list's body here is what let the two drift, hence
//  the forward.
//

import SwiftUI

@available(*, deprecated, renamed: "CommandLibraryView")
struct MQTTCommandEditorView: View {
    @Bindable var settings: DeviceSettings

    var body: some View {
        CommandLibraryView(settings: settings)
    }
}
