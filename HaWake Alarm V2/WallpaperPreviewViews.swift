//
//  WallpaperPreviewViews.swift
//  HaWake Alarm V2
//
//  Preset mockup thumbnail used by the Settings theme picker — a tiny
//  phone-frame preview hinting at each preset's wallpaper and glass style.
//

import SwiftUI

// MARK: - Preset Mockup Thumbnail

/// A tiny phone-frame mockup showing the wallpaper with simplified card overlays
/// that hint at the preset's glass style.
struct PresetMockupThumbnail: View {
    let wallpaper: UIImage?
    let glassVariant: Int
    let clearDimming: Double
    let tintRed: Double
    let tintGreen: Double
    let tintBlue: Double
    let tintOpacity: Double
    
    private let thumbWidth: CGFloat = 56
    private var thumbHeight: CGFloat { thumbWidth * 19.5 / 9 }
    private let cornerRadius: CGFloat = 6
    
    /// Card fill color derived from the glass variant settings
    private var cardFill: Color {
        switch glassVariant {
        case 1:
            // Clear glass — show as dark translucent overlay
            return Color.black.opacity(max(clearDimming, 0.15))
        case 2:
            // Tinted glass — use the tint color
            return Color(red: tintRed, green: tintGreen, blue: tintBlue)
                .opacity(max(tintOpacity * 0.6, 0.15))
        default:
            // Regular glass — light frosted appearance
            return Color.white.opacity(0.25)
        }
    }
    
    var body: some View {
        ZStack {
            // Wallpaper background
            if let wallpaper {
                Image(uiImage: wallpaper)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(uiColor: .systemGroupedBackground)
            }
            
            // Simplified card overlays — only for the default (no wallpaper) preset
            if wallpaper == nil {
                VStack(spacing: 2) {
                    Spacer()
                        .frame(height: thumbHeight * 0.18)
                    
                    mockCard(width: thumbWidth * 0.85, height: thumbHeight * 0.14)
                    mockCard(width: thumbWidth * 0.85, height: thumbHeight * 0.10)
                    
                    Spacer()
                }
            }
        }
        .frame(width: thumbWidth, height: min(thumbHeight, 105))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color(uiColor: .separator).opacity(0.4), lineWidth: 0.5)
        }
    }
    
    private func mockCard(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(cardFill)
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
            }
            .frame(width: width, height: height)
    }
}
