//
//  SystemColorPicker.swift
//  HaWake Alarm V2
//
//  UIColorPickerViewController, wrapped directly, with an explicit delegate.
//
//  Why not SwiftUI's ColorPicker (al-dgb): on iOS 26 its binding plumbing is
//  unreliable for the presented system picker — bound through a computed
//  Binding it delivered only the FIRST selection, and bound through plain
//  @State it delivered none at all on device. Owning the
//  UIColorPickerViewControllerDelegate makes delivery unconditional:
//  `didSelect(_:continuously:)` fires for every touch on the grid, spectrum,
//  sliders, and eyedropper, and we forward each one straight to the caller —
//  which is what lets the accent (or a command color) track the finger live.
//
//  Present inside a regular SwiftUI `.sheet`. The picker draws its own header
//  (title, eyedropper, X); the X lands in `colorPickerViewControllerDidFinish`,
//  which we surface as `onFinish` so the presenting view can drop the sheet.
//
//  PRESENTATION STATE MUST LIVE OUTSIDE ANY List/Form ROW (al-dgb). Because
//  `onPick` fires on every touch, the ancestor view re-renders mid-drag; a
//  `.sheet` attached to a Form row goes down with that row when the row is
//  rebuilt, so the picker dismissed itself the instant a color was chosen.
//  `SystemColorPickerRow` is therefore a plain row with an `action` — each
//  screen owns the `@State` flag and hangs the `.sheet` off its top-level
//  container (the Form itself), never off a Section or a row.
//
//  COMMIT ON CLOSE, NOT PER TICK (al-dgb round 4). Even with the sheet hoisted
//  to the Form, writing the @Observable store on every selection still tore the
//  presentation down on device — some layer of the sheet-over-sheet stack does
//  not survive the re-render. So while the picker is open, picks land only in a
//  `ColorSelectionBuffer` (a plain class; writing it renders NOTHING), and the
//  presenting screen commits the buffered color in the `.sheet`'s `onDismiss`,
//  which covers both the picker's X and a swipe-down. The store is never
//  touched while the picker is showing, so nothing can dismiss it.
//

import SwiftUI
import UIKit

struct SystemColorPickerSheet: UIViewControllerRepresentable {
    /// The color the picker opens on.
    let initial: Color
    var supportsAlpha: Bool = false
    /// Fired for EVERY selection change, continuous drags included.
    let onPick: (Color) -> Void
    /// Fired when the user closes the picker with its own X.
    var onFinish: () -> Void = {}

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = supportsAlpha
        picker.selectedColor = UIColor(initial)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIColorPickerViewController, context: Context) {
        // Deliberately empty: the picker owns the selection while it is up.
        // Writing selectedColor from SwiftUI state here is exactly the feedback
        // loop that broke the native ColorPicker.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onFinish: onFinish)
    }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        let onPick: (Color) -> Void
        let onFinish: () -> Void

        init(onPick: @escaping (Color) -> Void, onFinish: @escaping () -> Void) {
            self.onPick = onPick
            self.onFinish = onFinish
        }

        func colorPickerViewController(_ viewController: UIColorPickerViewController,
                                       didSelect color: UIColor,
                                       continuously: Bool) {
            onPick(Color(uiColor: color))
        }

        func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
            onFinish()
        }
    }
}

/// Holds the color picked while the system picker is up. A plain class, NOT
/// @Observable and NOT @State-driven data: writing `latest` must render
/// nothing, or the picker dismisses itself (see file header). Keep the
/// instance in `@State` so it survives re-renders; commit with `take()` from
/// the sheet's `onDismiss`.
final class ColorSelectionBuffer {
    var latest: Color?

    /// Returns the buffered pick and clears it, so one selection commits once.
    func take() -> Color? {
        defer { latest = nil }
        return latest
    }
}

/// The "Custom Color" row both color grids use to open the system picker:
/// label + caption on the left, the current color as a well-style swatch on
/// the right. Replaces the native `ColorPicker` row one-for-one.
///
/// Deliberately owns NO presentation state — see the file header. The row only
/// reports the tap; the presenting screen holds the flag and the `.sheet`.
struct SystemColorPickerRow: View {
    let title: String
    let caption: String
    /// Live current color, shown in the trailing swatch.
    let color: Color
    /// The trailing swatch's diameter. Defaults to the compact row swatch; the
    /// theme accent picker passes a larger value so the well itself carries the
    /// big colour preview, rather than a separate header card doing it.
    var swatchDiameter: CGFloat = 28
    /// Asks the presenting screen to raise `SystemColorPickerSheet`.
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                HStack {
                    Text(title)
                    Spacer(minLength: 0)
                    Circle()
                        .fill(color)
                        .frame(width: swatchDiameter, height: swatchDiameter)
                        .overlay {
                            Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                        }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityLabel(title)
            .accessibilityHint("Opens the color picker")

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
