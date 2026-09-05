//
//  OnboardingView.swift
//  HaWake Alarm V2
//
//  First-launch onboarding — explains required permissions and
//  requests them all with a single "Continue" button.
//
//  BACKGROUND: the app's own home wallpaper for the current appearance, over an
//  adaptive scrim, rather than the flat `Color.black` this used to be. Onboarding
//  was the one screen that ignored the app's theming entirely, which made it read
//  as a generic dark modal instead of the product about to be used. AppDelegate
//  seeds the built-in presets and applies Neon Silk before this ever renders, so a
//  light AND dark wallpaper exist on first launch; the accent gradient is only a
//  fallback for a missing/disabled wallpaper.
//
//  Because the scrim adapts, every label uses SEMANTIC colors (.primary /
//  .secondary) instead of hardcoded white — this screen now follows light/dark.
//
//  CONSENT: "Continue" is always tappable. A disabled button tells VoiceOver
//  "dimmed" and nothing about why; a live one can say what's missing. Tapping it
//  without consent nudges the consent row (tint + border, plus a shake unless
//  Reduce Motion is on) and announces the reason. Tapping Continue is NEVER
//  treated as agreement — the button says "Continue", so reading it as consent
//  would be putting words in the user's mouth. Ticking the box stays deliberate.
//

import SwiftUI
import SafariServices
import UIKit

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRequestingPermissions = false
    @State private var safariURL: URL? = nil
    @State private var agreedToTerms = false
    /// Transient emphasis on the consent row after a Continue tap without consent.
    @State private var consentNeedsAttention = false
    @State private var consentShake: CGFloat = 0
    /// How many permission cards have entered — drives the staggered slide-in.
    @State private var cardsRevealed = 0
    /// Advances to step 2 (data preferences) once permissions are requested.
    @State private var showingPreferences = false
    /// Visible height of the scroll area, used as a MINIMUM so short content
    /// centres and long content scrolls instead of being compressed.
    @State private var scrollAreaHeight: CGFloat = 0

    let settings = DeviceSettings.shared

    // The onboarding screens are ALWAYS dark, whatever the system appearance.
    // The light treatment needed a thinner scrim to avoid washing the wallpaper
    // out, which then cost text contrast — two constraints pulling opposite ways
    // on a screen nobody sees twice. The dark version reads well over any
    // wallpaper, so both screens pin to it and the whole tradeoff disappears.
    // `.environment(\.colorScheme, .dark)` on the root makes semantic colors,
    // asset variants, materials and glass all resolve dark to match.
    private let isDark = true
    private var accent: Color { settings.appAccent(for: .dark) }

    /// The home wallpaper for the CURRENT appearance — the same image and the
    /// same resolution path the alarm list uses.
    private var wallpaper: UIImage? {
        guard settings.homeWallpaperEnabled else { return nil }
        return settings.loadWallpaper(for: settings.activeHomeWallpaperKey(forDark: isDark))
    }

    var body: some View {
        if showingPreferences {
            // Step 2. Permissions have been requested and terms agreed; this
            // screen owns its own commit and finishes onboarding.
            DataPreferencesView(isPartOfOnboarding: true) {
                settings.hasCompletedOnboarding = true
                dismiss()
            }
        } else {
            permissionsStep
        }
    }

    private var permissionsStep: some View {
        ZStack {
            OnboardingBackdrop(
                accent: accent,
                isDark: isDark,
                wallpaper: OnboardingBackdrop.wallpaper(for: settings, isDark: isDark)
            )

            // Consent + Continue are a SIBLING of the scroll area, not scrolling
            // content — they used to sit inside the ScrollView separated by
            // fixed-height Spacers, so on a short screen the primary action could
            // scroll out of reach.
            //
            // Content is centred with a MINIMUM height rather than
            // `containerRelativeFrame(.vertical)`, which sets an exact height:
            // when content outgrew it, SwiftUI compressed the lowest-priority
            // views and truncated text (see DataPreferencesView, where a longer
            // subtitle made a card title read "Usage Data & Crash…"). minHeight
            // centres when there's room and scrolls when there isn't.
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        OnboardingHero(
                            title: "Welcome to Allarise",
                            subtitle: "A few permissions power Allarise's features.",
                            isDark: isDark
                        )
                        permissionRows
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: scrollAreaHeight, alignment: .center)
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { scrollAreaHeight = geometry.size.height }
                            .onChange(of: geometry.size.height) { _, new in
                                scrollAreaHeight = new
                            }
                    }
                }

                footer
            }
        }
        .environment(\.colorScheme, .dark)
        .interactiveDismissDisabled()
        .sheet(item: $safariURL) { url in
            SafariView(url: url)
                .ignoresSafeArea()
        }
    }

    // Backdrop and hero now come from OnboardingChrome.swift, shared with
    // DataPreferencesView — a local copy of either is how the two screens drift.

    // MARK: - Permissions

    /// ONE grouped card holding both rows, divided — not two separate cards, and
    /// not bare text.
    ///
    /// Bare typography (no container at all) left the rows floating with nothing
    /// holding them to the screen. The original's answer was a translucent
    /// `white.opacity(0.08)` rectangle per row, which is the most generic
    /// dark-UI move there is. A single material group with an inset divider is
    /// the app's own grouped-list language — the same shape Settings uses — so
    /// it reads as structure rather than decoration, and one object anchors
    /// better than two.
    private var permissionRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            permissionCard(
                index: 0,
                icon: "bell.badge.fill",
                title: "Notifications & Alarms",
                description: "Required to ring your alarms, show alerts on the Lock Screen, and deliver snooze reminders.",
                isDark: isDark
            )

            permissionCard(
                index: 1,
                icon: "location.fill",
                title: "Location",
                description: "Used for Wi-Fi network detection to enable MQTT home/away switching, and to power the optional Weather card on your alarm screen.",
                isDark: isDark
            )

            // Sits tight under the Location card, grouped-list-footer style —
            // it describes the two cards, so it belongs with them. It briefly
            // lived down in the pinned footer instead, which put the screen's
            // leftover height between it and the thing it was explaining.
            // .secondary rather than .tertiary because it's over a wallpaper.
            Text("You can change these permissions anytime in Settings.")
                .font(.footnote)
                .foregroundStyle(onboardingSecondary(isDark))
                .padding(.horizontal, 4)
                .padding(.top, 2)
                .opacity(cardsRevealed > 1 ? 1 : 0)
                .animation(.easeOut(duration: 0.35), value: cardsRevealed)
        }
        .onAppear(perform: revealCards)
    }

    /// One permission box. Separate cards rather than one grouped card with a
    /// divider, so each can enter on its own — a shared container would have sat
    /// static while its contents slid, which reads as broken rather than staged.
    private func permissionCard(index: Int, icon: String, title: String, description: String, isDark: Bool) -> some View {
        let shown = cardsRevealed > index
        return PermissionRow(icon: icon, tint: accent, title: title, description: description, isDark: isDark)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Liquid Glass, sized and rounded like a Lock Screen notification —
            // the same `.glassEffect` the Notes command squares and the player
            // bubbles use, so this is the app's existing glass, not a new look.
            // Replaces a flat `.regularMaterial` fill plus a hand-drawn hairline
            // border; glass brings its own edge and depth, so the stroke goes.
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .shadow(color: .black.opacity(isDark ? 0.35 : 0.12), radius: 10, y: 4)
            // Held in the hierarchy and moved, rather than inserted — inserting
            // would reflow everything below them as each one lands.
            .offset(x: shown ? 0 : -cardTravel)
            .opacity(shown ? 1 : 0)
    }

    /// How far off to the left the cards start. Reduce Motion gets a plain fade.
    /// A longer glide also reads slower, so this is part of the pacing.
    private var cardTravel: CGFloat { reduceMotion ? 0 : 90 }

    /// Beat before the first card lands, so the header reads first.
    private static let firstCardDelay: TimeInterval = 0.45
    /// Gap between the two cards. Sized to READ the first one, not merely to
    /// stagger it — earlier passes at 0.14s and 0.30s were paced as a visual
    /// flourish, but the point is that someone finishes "Notifications & Alarms"
    /// before Location arrives. ~15 words at an unhurried pace is about this
    /// long. Nothing is gated on it: Continue is live the whole time, so a user
    /// who doesn't want to wait never has to.
    private static let cardReadingGap: TimeInterval = 1.2

    /// Staggered entrance, one card after the other.
    private func revealCards() {
        guard cardsRevealed == 0 else { return }
        for step in 1...2 {
            let delay = Self.firstCardDelay + Double(step - 1) * Self.cardReadingGap
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(reduceMotion
                              ? .easeOut(duration: 0.45)
                              : .spring(response: 0.72, dampingFraction: 0.84)) {
                    cardsRevealed = step
                }
            }
        }
    }

    // MARK: - Footer (pinned)

    private var footer: some View {
        VStack(spacing: 14) {
            consentRow
            continueButton
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .background(alignment: .top) {
            // Softens the boundary where scrolling text passes behind the footer.
            LinearGradient(
                colors: isDark
                    ? [.black.opacity(0), .black.opacity(0.35)]
                    : [.white.opacity(0), .white.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private var consentRow: some View {
        // CENTER against the whole text block. Two earlier attempts aligned the
        // box to the first text line (.top, then .firstTextBaseline) on the
        // theory that a tall glyph next to a short line reads better that way —
        // it doesn't. The label wraps to two lines, so anything but centring
        // leaves the box visibly high.
        HStack(alignment: .center, spacing: 8) {
            // Its own button, 30×44: full-height tap target without a wide box
            // pushing the glyph away from the leading margin. The label stays
            // outside the button so its Terms/Privacy links remain tappable.
            Button {
                withAnimation(.smooth(duration: 0.18)) {
                    agreedToTerms.toggle()
                    if agreedToTerms { consentNeedsAttention = false }
                }
            } label: {
                Image(systemName: agreedToTerms ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(agreedToTerms ? accent : Color.secondary)
                    .frame(width: 30, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("I agree to the Terms of Use and Privacy Policy")
            .accessibilityAddTraits(agreedToTerms ? [.isSelected] : [])

            Text(termsAgreementText)
                .font(.footnote)
                .foregroundStyle(onboardingSecondary(isDark))
                .tint(accent)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(consentNeedsAttention ? 0.08 : 0))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(consentNeedsAttention ? 0.38 : 0),
                                      lineWidth: 1)
                )
        )
        .offset(x: consentShake)
        // Route the inline Terms/Privacy links to the in-app Safari sheet instead
        // of leaving the app.
        .environment(\.openURL, OpenURLAction { url in
            safariURL = url
            return .handled
        })
    }

    private var continueButton: some View {
        Button {
            guard agreedToTerms else {
                nudgeConsent()
                return
            }
            requestAllPermissions()
        } label: {
            HStack {
                Spacer()
                if isRequestingPermissions {
                    ProgressView().tint(.white)
                } else {
                    Text("Continue").fontWeight(.semibold)
                }
                Spacer()
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        // Quieter until consent is given — tappable, but not pretending to be
        // ready to go.
        .tint(agreedToTerms ? accent : accent.opacity(0.5))
        .disabled(isRequestingPermissions)
        .accessibilityHint(agreedToTerms
                           ? ""
                           : "Agree to the Terms of Use and Privacy Policy first")
    }

    /// Points at what's missing, without turning the screen into an error state.
    private func nudgeConsent() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)

        withAnimation(.smooth(duration: 0.2)) { consentNeedsAttention = true }

        if !reduceMotion {
            withAnimation(.easeInOut(duration: 0.07).repeatCount(4, autoreverses: true)) {
                consentShake = 5
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { consentShake = 0 }
        }

        UIAccessibility.post(notification: .announcement,
                             argument: "Agree to the Terms of Use and Privacy Policy to continue.")

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation(.smooth(duration: 0.25)) { consentNeedsAttention = false }
        }
    }

    /// Checkbox label with inline Terms/Privacy links (routed to the in-app Safari sheet
    /// by the `.environment(\.openURL)` handler on the row).
    private var termsAgreementText: AttributedString {
        let md = "I agree to the [Terms of Use](\(AppLinks.termsString)) and [Privacy Policy](\(AppLinks.privacyString))."
        return (try? AttributedString(markdown: md)) ?? AttributedString(md)
    }

    private func requestAllPermissions() {
        isRequestingPermissions = true
        
        Task { @MainActor in
            // 1. Notifications + AlarmKit (async — shows system prompt)
            _ = await DualAlarmCoordinator.shared.requestAuthorization()
            
            // 2. Location (shows system prompt if .notDetermined)
            NetworkMonitor.shared.requestLocationPermission()
            
            // Brief delay to let the last permission dialog settle
            try? await Task.sleep(for: .milliseconds(500))
            
            // Record terms agreement. Onboarding is NOT complete yet — step 2
            // (data preferences) owns that, so a user who somehow leaves between
            // the two steps is re-shown the flow rather than skipping the
            // consent prompt entirely.
            settings.agreedTermsVersion = DeviceSettings.currentTermsVersion
            isRequestingPermissions = false
            withAnimation(.smooth(duration: 0.3)) { showingPreferences = true }
        }
    }
}

// MARK: - Safari View

private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

// MARK: - Terms Update View

/// Shown to existing users when terms have been updated (agreedTermsVersion < currentTermsVersion).
/// Non-dismissible — user must tap "I Agree" to continue using the app.
struct TermsUpdateView: View {
    @Environment(\.dismiss) private var dismiss
    /// Dark accent to match: this screen paints a hardcoded black background, so
    /// resolving the accent against a light appearance gave it a colour tuned for
    /// a background it never has. Same reasoning that pins the onboarding screens.
    private var accent: Color { settings.appAccent(for: .dark) }
    @State private var safariURL: URL? = nil
    let settings = DeviceSettings.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Icon + heading
                VStack(spacing: 16) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(accent)

                    Text("We've updated our Terms & Privacy Policy")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Text("Please review and agree to the updated policies to continue using Allarise.")
                        .font(.body)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                // Read the terms/privacy links
                HStack(spacing: 20) {
                    Button {
                        safariURL = AppLinks.terms
                    } label: {
                        HStack(spacing: 4) {
                            Text("Terms of Use")
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    Button {
                        safariURL = AppLinks.privacy
                    } label: {
                        HStack(spacing: 4) {
                            Text("Privacy Policy")
                            Image(systemName: "arrow.up.right")
                        }
                    }
                }
                .font(.subheadline)
                .foregroundColor(accent)

                Spacer()

                // I Agree button
                Button {
                    settings.agreedTermsVersion = DeviceSettings.currentTermsVersion
                    dismiss()
                } label: {
                    HStack {
                        Spacer()
                        Text("I Agree")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 32)

                Spacer()
                    .frame(height: 16)
            }
        }
        .environment(\.colorScheme, .dark)
        .interactiveDismissDisabled()
        .sheet(item: $safariURL) { url in
            SafariView(url: url)
                .ignoresSafeArea()
        }
    }
}

// MARK: - Permission Row

/// Fixed icon column + left-aligned title and body. No background, no border —
/// the row is typography, not a component. One tint for both icons rather than a
/// red bell and a blue pin: a single accent reads as designed, two arbitrary
/// colors read as decoration.
private struct PermissionRow: View {
    let icon: String
    let tint: Color
    let title: String
    let description: String
    let isDark: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 30, alignment: .center)
                // Optical alignment: drops the glyph onto the title's line rather
                // than its cap height.
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 5) {
                // Both texts fixedSize so neither can be truncated when the row
                // is narrow — the title used to be the only compressible one.
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(onboardingSecondary(isDark))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
