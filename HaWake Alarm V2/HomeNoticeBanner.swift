//
//  HomeNoticeBanner.swift
//  HaWake Alarm V2
//
//  The shared body of the accent-coloured, dismissible home-screen notices.
//
//  WHY THIS EXISTS
//  ---------------
//  `NWSRemovalBanner`, `DynamicModeBanner` and `RadioPersistenceBanner` were
//  three byte-identical copies of the same 40 lines: icon, bold title, caption
//  body, ✕, accent fill at 0.9, the same paddings, the same transition. Adding
//  a fourth (`SleptThroughBanner`, al-bee.5) was exactly the moment CLAUDE.md
//  names — "if a fourth kind appears, factor out the shared component" — so
//  this became that component. (`SleptThroughBanner` was later removed
//  2026-08-10 / al-ad1; the remaining three still render through it.)
//
//  WHAT IS DELIBERATELY NOT HERE
//  -----------------------------
//  `AlarmPermissionBanner` (red) and `BackgroundRefreshBanner` (orange) are a
//  different thing wearing similar clothes: they are BUTTONS with a chevron
//  and no ✕, and their colour is load-bearing — orange and red on the home
//  screen mean "your alarms may not ring right now", a monopoly the accent
//  notices exist to stay out of. Folding them in would either lose the chevron
//  affordance or add a dismiss control to a warning that must not be
//  dismissible. They stay as they are.
//
//  Each notice keeps its own eligibility logic, copy and store. This owns
//  nothing but the chrome.
//

import SwiftUI

/// One home-screen notice: accent-filled, non-tappable body, ✕ to dismiss.
///
/// Non-tappable on purpose — no home banner deep-links, and a banner that
/// looks tappable but is not is worse than a plain one. Copy names the
/// destination in words instead.
struct HomeNoticeBanner: View {

    let systemImage: String
    let title: String
    let message: String
    /// Nil hides the ✕ — for a notice that clears itself.
    let onDismiss: (() -> Void)?

    @State private var settings = DeviceSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    init(
        systemImage: String,
        title: String,
        message: String,
        onDismiss: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, onDismiss == nil ? 16 : 8)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(settings.appAccent(for: colorScheme).opacity(0.9))
        )
        .padding(.horizontal)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityElement(children: .contain)
    }
}
