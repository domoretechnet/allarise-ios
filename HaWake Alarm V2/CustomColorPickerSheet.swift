//
//  CustomColorPickerSheet.swift
//  HaWake Alarm V2
//
//  Our own compact colour picker — the replacement for the system
//  `UIColorPickerViewController` sheet at the "Custom Color" wells.
//
//  Why not the system picker (which SystemColorPicker.swift still wraps): it
//  forces a saved-swatches palette and a "+" row we don't want, gives no Done
//  affordance (it applies live and is only dismissed by swiping), and we can't
//  size it, so it floated in dead space or clipped its last row. This draws only
//  what we need — a saturation/brightness field, a hue slider, a live preview
//  and an explicit Done — with stock SwiftUI gradients and NO third-party
//  dependency. The well-known technique (an SB square tinted by a hue slider) is
//  reproduced here rather than pulled from a package.
//
//  Same call shape as `SystemColorPickerSheet` on purpose, so the two wells swap
//  one for the other:
//    • `onPick` fires live as the finger moves — the caller buffers it.
//    • `onFinish` fires on Done; the presenting screen drops the sheet, and its
//      `.sheet(onDismiss:)` commits the buffered colour (covers Done AND swipe).
//
//  Unlike the system picker, this is plain SwiftUI bound to local @State, so
//  updating per drag can't tear its own sheet down — the al-dgb feedback loop
//  was specific to writing the @Observable store while the SYSTEM picker was up.
//  We still commit on dismiss for parity with the old flow, so nothing about how
//  a colour is saved changes.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct CustomColorPickerSheet: View {
    /// The colour the picker opens on.
    let initial: Color
    /// Fired for every change, continuous drags included. The caller buffers it.
    let onPick: (Color) -> Void
    /// Fired when the user taps Done.
    var onFinish: () -> Void = {}

    // Hue / Saturation / Brightness are the working representation: the SB field
    // and hue slider map onto them directly, and Color(hue:saturation:brightness:)
    // is a lossless round-trip for the RGB triple we ultimately store.
    @State private var hue: Double = 0
    @State private var saturation: Double = 1
    @State private var brightness: Double = 1
    @State private var didSeed = false

    private var current: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    private var hexLabel: String {
        let rgb = commandColorComponents(of: current)
        return "#" + commandColorHex(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                preview
                saturationBrightnessField
                hueSlider
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Custom Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onFinish() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear(perform: seedFromInitial)
        }
    }

    // MARK: - Pieces

    /// The big live preview — the current colour and its hex, the same prominent
    /// bubble the well shows, so what you are mixing is never in doubt.
    private var preview: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(current)
                .frame(width: 64, height: 64)
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1) }
            VStack(alignment: .leading, spacing: 2) {
                Text("Custom Color").font(.headline)
                Text(hexLabel)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Selected colour \(hexLabel)")
    }

    /// The saturation (x, 0…1 left→right) and brightness (y, 1…0 top→bottom)
    /// field, tinted by the current hue. White at the left edge, black at the
    /// bottom — the standard HSB square.
    private var saturationBrightnessField: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(hue: hue, saturation: 1, brightness: 1))
                LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)

                thumb
                    .position(x: saturation * size.width,
                              y: (1 - brightness) * size.height)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        saturation = clamp(value.location.x / size.width)
                        brightness = clamp(1 - value.location.y / size.height)
                        emit()
                    }
            )
        }
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityLabel("Saturation and brightness")
    }

    /// The hue slider — a full rainbow, thumb at `hue`.
    private var hueSlider: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6.0)
                        .map { Color(hue: $0, saturation: 1, brightness: 1) },
                    startPoint: .leading, endPoint: .trailing
                )
                thumb
                    .position(x: hue * width, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        hue = clamp(value.location.x / width)
                        emit()
                    }
            )
        }
        .frame(height: 30)
        .clipShape(Capsule())
        .overlay { Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1) }
        .accessibilityLabel("Hue")
    }

    /// The draggable indicator, shared by both controls: a white ring with a thin
    /// dark edge so it reads on any colour underneath.
    private var thumb: some View {
        Circle()
            .fill(current)
            .frame(width: 26, height: 26)
            .overlay { Circle().strokeBorder(.white, lineWidth: 3) }
            .overlay { Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1) }
            .shadow(radius: 2)
    }

    // MARK: - Helpers

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    private func emit() { onPick(current) }

    /// Seed HSB from the opening colour, once. A colour with no chroma (a grey)
    /// leaves hue at its default, which is fine — moving the hue slider gives it
    /// one.
    private func seedFromInitial() {
        guard !didSeed else { return }
        didSeed = true
        #if canImport(UIKit)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if UIColor(initial).getHue(&h, saturation: &s, brightness: &b, alpha: &a) {
            hue = Double(h)
            saturation = Double(s)
            brightness = Double(b)
        }
        #endif
    }
}
