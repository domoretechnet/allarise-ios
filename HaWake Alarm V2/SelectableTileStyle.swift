//
//  SelectableTileStyle.swift
//  HaWake Alarm V2
//
//  Shared selected-tile styling for the app's selectable squares/pills
//  (mission squares, snooze/skip mode tiles, command-mode squares,
//  appearance/persistence cards, radio filter pills, …).
//
//  Selected state reads as flat pastel paper — a light accent wash with no
//  material, border, or glow. Unselected state is a flat `tertiarySystemFill`
//  fill, no border, dimmed to 0.6 opacity.
//

import SwiftUI

struct SelectableTileStyle: ViewModifier {
    let isSelected: Bool
    let accent: Color
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isSelected
                          ? AnyShapeStyle(accent.opacity(0.28))
                          : AnyShapeStyle(Color(uiColor: .tertiarySystemFill)))
            }
            .opacity(isSelected ? 1.0 : 0.6)
    }
}

extension View {
    /// Applies the app's shared selected-tile styling.
    ///
    /// Selected: flat pastel accent wash ("colored paper"), no border or glow.
    /// Unselected: flat `tertiarySystemFill`, no border, dimmed to 0.6.
    ///
    /// Pair with `.foregroundStyle(isSelected ? accent : Color.primary)`
    /// at the call site so the glyph/text tints with the selection.
    func selectableTile(isSelected: Bool, accent: Color, cornerRadius: CGFloat = 16) -> some View {
        modifier(SelectableTileStyle(isSelected: isSelected, accent: accent, cornerRadius: cornerRadius))
    }
}
