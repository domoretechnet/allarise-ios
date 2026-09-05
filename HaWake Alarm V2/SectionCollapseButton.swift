//
//  SectionCollapseButton.swift
//  HaWake Alarm V2
//
//  A full-width borderless row with a centered up-chevron that collapses an
//  expanded alarm-editor accordion section back to its summary card. Append it
//  as the last row of a section's expanded content and pass a `collapse` action
//  that clears the shared `expandedSection` binding. The action runs inside a
//  smooth animation so the section folds back with the same motion it opened.
//

import SwiftUI

struct SectionCollapseButton: View {
    /// Theme accent used to tint the chevron (each section already computes one).
    var accent: Color
    /// Collapse action — typically `expandedSection.wrappedValue = nil`.
    var collapse: () -> Void

    var body: some View {
        Button {
            withAnimation(.smooth) {
                collapse()
            }
        } label: {
            Image(systemName: "chevron.up")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}
