//
//  VerseOfDayCardView.swift
//  HaWake Alarm V2
//
//  Full-screen-capable card that presents a single day's verse over a portrait
//  background image (or a generated gradient fallback), with a legibility scrim
//  and a theme-accent-aware "Continue" affordance.
//
//  This view is NOT wired into any flow yet — the future After-Alarm pipeline
//  will present it. It is exercised today only by the DEBUG `-verseDebug` harness.
//
//  MEMORY DISCIPLINE (explicit constraint): the background image is decoded here,
//  at display time, via ImageIO downsampling (CGImageSourceCreateThumbnailAtIndex)
//  sized to the actual card, NOT a full-resolution decode. The decoded image is
//  held only in this view's `@State` and released when the view goes away — no
//  decoded image is cached beyond the view's lifetime, and VerseOfDayService
//  never decodes at all.
//

import ImageIO
import SwiftUI
import UIKit

struct VerseOfDayCardView: View {
    let verse: VerseOfDay
    /// Small label above the verse, for when the card is not showing what it
    /// normally shows. The preview passes "Yesterday's verse"; the real
    /// post-alarm card passes nil and looks exactly as it always has.
    var caption: String? = nil
    /// Placeholder affordance closure. The future pipeline supplies the real
    /// "dismiss / continue into the day" action; nothing is wired yet.
    var onContinue: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    /// Downsampled background. nil → the generated gradient shows (either because
    /// no cached image exists, or the decode has not finished / failed).
    @State private var backgroundImage: UIImage?

    private var accent: Color {
        DeviceSettings.shared.appAccent(for: colorScheme)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                background(size: geometry.size)
                legibilityScrim
                content
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .task(id: verse.id) {
                await loadBackground(targetSize: geometry.size)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Background

    @ViewBuilder
    private func background(size: CGSize) -> some View {
        if let backgroundImage {
            Image(uiImage: backgroundImage)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            // Generated gradient — theme-accent-tinted, no bundled assets.
            LinearGradient(
                colors: [
                    accent.opacity(0.85),
                    accent.opacity(0.35),
                    Color.black.opacity(0.9),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    /// Bottom-anchored dark scrim so the overlaid text stays legible over any
    /// imagery.
    private var legibilityScrim: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0.0),
                Color.black.opacity(0.35),
                Color.black.opacity(0.85),
            ],
            startPoint: .center,
            endPoint: .bottom
        )
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    // Quiet, and only when the host asks for it — the preview says
                    // so rather than leaving the user to wonder why the verse looks
                    // different from the one they get in the morning.
                    if let caption {
                        Text(caption)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }

                    // Adaptive typography: short verses keep the big serif; long
                    // ones (Isaiah 41:10 is a paragraph) step down so the card
                    // never crowds or truncates. minimumScaleFactor is the
                    // last-resort safety net.
                    Text(verse.text)
                        .font(.system(verseTextStyle, design: .serif, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineSpacing(4)
                        .minimumScaleFactor(0.75)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Text(verse.reference)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)

                    Text(verse.translation)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(accent.opacity(0.9))
                        )
                }
            }

            // Generous gap: the verse is the point of the card and was reading as
            // crowded against the button. The block above is bottom-anchored, so
            // widening this pushes the verse UP rather than the button down.
            continueButton
                .padding(.top, 56)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 44)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Verse text size stepped by length so long passages fit comfortably.
    private var verseTextStyle: Font.TextStyle {
        switch verse.text.count {
        case ..<120:  return .title
        case ..<220:  return .title2
        default:      return .title3
        }
    }

    private var continueButton: some View {
        Button(action: onContinue) {
            Text("Continue")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 60)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(accent)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Downsampled decode (ImageIO, off the main thread)

    private func loadBackground(targetSize: CGSize) async {
        guard let url = verse.imageURL else {
            backgroundImage = nil
            return
        }

        // Longest edge in pixels — enough to fill the card at native scale, but
        // never a full-resolution decode of the source JPEG.
        let maxPixel = max(targetSize.width, targetSize.height) * displayScale

        let decoded = await Task.detached(priority: .userInitiated) {
            Self.downsampledImage(at: url, maxPixelSize: maxPixel)
        }.value

        guard !Task.isCancelled else { return }
        backgroundImage = decoded
    }

    /// Decode `url` to a UIImage no larger than `maxPixelSize` on its longest
    /// edge, using ImageIO thumbnailing so the full-resolution image is never
    /// materialized in memory.
    nonisolated private static func downsampledImage(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

#if DEBUG
#Preview {
    VerseOfDayCardView(
        verse: VerseOfDay(
            date: "2026-07-23",
            reference: "Philippians 4:13",
            text: "I can do all things through Christ, who strengthens me.",
            translation: "WEB",
            imageURL: nil,
            isFallback: true
        )
    )
}
#endif
