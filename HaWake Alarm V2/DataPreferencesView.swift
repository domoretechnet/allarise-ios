//
//  DataPreferencesView.swift
//  HaWake Alarm V2
//
//  The second first-run screen: anonymous usage/crash reporting, and optional
//  product-update notifications. Both OFF by default and never pre-ticked —
//  consent that arrives already granted isn't consent.
//
//  SHOWN IN TWO PLACES, which is why it's its own view rather than a page baked
//  into `OnboardingView`:
//    • new installs — step 2 of onboarding, after permissions and terms
//    • existing installs — once, standalone, for users upgrading from a build
//      that predates the prompt (`hasAnsweredDataPreferences`)
//
//  It wears the same chrome as the welcome screen (`OnboardingChrome.swift`):
//  blurred wallpaper, centred hero, Liquid Glass cards, staggered entrance.
//
//  THE NUDGE. Analytics is encouraged, never required. Tapping the primary
//  button with it off highlights the card once and shows the optional note;
//  tapping again proceeds with it off. See `NudgeState` for the App Store and
//  GDPR reasoning behind one-shot rather than blocking.
//
//  Nothing here starts collecting anything. The toggles only record intent —
//  an analytics SDK must not initialise until `analyticsOptIn` is true, since
//  in the EU consent has to precede collection rather than switch it off after.
//

import SwiftUI
import UIKit

struct DataPreferencesView: View {
    /// Title/subtitle differ slightly between first-run and the one-off prompt
    /// for existing users, but nothing else does.
    var isPartOfOnboarding: Bool = true
    /// Called when the user commits. The host persists and dismisses.
    var onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var analyticsOptIn = false
    @State private var productUpdatesOptIn = false
    @State private var cardsRevealed = 0
    /// The one-time explainer shown when the user commits with analytics off.
    @State private var showAnalyticsExplainer = false
    @State private var hasShownAnalyticsExplainer = false
    /// Visible height of the scroll area, used as a MINIMUM so short content
    /// centres and long content scrolls instead of being compressed.
    @State private var scrollAreaHeight: CGFloat = 0

    private let settings = DeviceSettings.shared

    // The onboarding screens are ALWAYS dark, whatever the system appearance.
    // The light treatment needed a thinner scrim to avoid washing the wallpaper
    // out, which then cost text contrast — two constraints pulling opposite ways
    // on a screen nobody sees twice. The dark version reads well over any
    // wallpaper, so both screens pin to it and the whole tradeoff disappears.
    // `.environment(\.colorScheme, .dark)` on the root makes semantic colors,
    // asset variants, materials and glass all resolve dark to match.
    private let isDark = true
    private var accent: Color { settings.appAccent(for: .dark) }

    private var title: String { "A Few Quick Things" }

    /// Deliberately NOT another "change them anytime in Settings" line — the
    /// permissions screen already ends on that sentence, and repeating it makes
    /// the two screens read as the same screen twice. This says what the
    /// previous one can't: nothing here is on, and nothing here touches alarms.
    private var subtitle: String {
        isPartOfOnboarding
            ? "These options are off unless you decide to turn them on, and neither is required for the app to work."
            // Existing users need one extra beat of context — they've used the
            // app for a while and this screen has never appeared before.
            : "New in this version. These options are off unless you decide to turn them on, and neither is required for the app to work."
    }

    var body: some View {
        ZStack {
            OnboardingBackdrop(
                accent: accent,
                isDark: isDark,
                wallpaper: OnboardingBackdrop.wallpaper(for: settings, isDark: isDark)
            )

            // ScrollView and footer are SIBLINGS, not a scroll view with a
            // bottom safeAreaInset, so the scroll area's own geometry is exactly
            // the space the content may occupy.
            //
            // Centring previously used `containerRelativeFrame(.vertical)`, which
            // sets an EXACT height — once the content grew past it (a three-line
            // subtitle was enough) SwiftUI compressed the lowest-priority views
            // and truncated a card title to "Usage Data & Crash…". `minHeight`
            // centres when there's room and simply scrolls when there isn't, so
            // long copy and large Dynamic Type can't squeeze the text.
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        OnboardingHero(title: title, subtitle: subtitle, isDark: isDark)
                        cards
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

            if showAnalyticsExplainer {
                analyticsExplainer
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(1)
            }
        }
        .environment(\.colorScheme, .dark)
        .interactiveDismissDisabled()
        .onAppear {
            // Seed from stored values so re-entry (or a future Settings launch
            // of this screen) reflects reality rather than resetting to off.
            analyticsOptIn = settings.analyticsOptIn
            productUpdatesOptIn = settings.productUpdatesOptIn
            revealCards()
        }
    }

    // MARK: - Cards

    private var cards: some View {
        VStack(alignment: .leading, spacing: 12) {
            toggleCard(
                index: 0,
                icon: "chart.bar.fill",
                title: "Usage Data & Crash Reports",
                description: "Anonymous. Helps find crashes and shows which features get used. Never tied to you, never sold.",
                isOn: $analyticsOptIn,
                highlighted: false
            )

            toggleCard(
                index: 1,
                icon: "sparkles",
                title: "Product Updates",
                description: "Occasional notifications about new features and important changes. No marketing.",
                isOn: $productUpdatesOptIn,
                highlighted: false
            )
        }
    }

    private func toggleCard(index: Int,
                            icon: String,
                            title: String,
                            description: String,
                            isOn: Binding<Bool>,
                            highlighted: Bool) -> some View {
        let shown = cardsRevealed > index
        return HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(accent)
                .frame(width: 30, alignment: .center)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 5) {
                // `fixedSize(vertical:)` on the TITLE as well as the description.
                // Without it the title was the only text free to be compressed,
                // so a narrow text column (icon + toggle both take width) made
                // SwiftUI truncate it to "Usage Data & Crash…" instead of
                // wrapping to a second line.
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(onboardingSecondary(isDark))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(accent)
                .padding(.top, 2)
        }
        .onboardingGlassCard(isDark: isDark)
        .onboardingAttention(highlighted, cornerRadius: 26)
        .offset(x: shown ? 0 : -cardTravel)
        .opacity(shown ? 1 : 0)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Footer

    /// No footnote above the button. The subtitle already establishes that these
    /// are optional, so a second "Optional —" line said the same thing twice and
    /// pushed the primary action down for nothing.
    private var footer: some View {
        VStack(spacing: 14) {
            Button(action: commit) {
                HStack {
                    Spacer()
                    Text(isPartOfOnboarding ? "Get Started" : "Done")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(accent)
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .background(alignment: .top) {
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

    // MARK: - Explainer

    /// Shown ONCE, when the user commits with analytics off — it makes the case,
    /// then gets out of the way.
    ///
    /// Two equally-weighted buttons, both one tap, both on the same surface.
    /// That's the point: an earlier design made declining mean "tap Get Started
    /// again", which is extra effort that only refusers pay. EDPB Guidelines
    /// 03/2022 call that out as asymmetric friction, and it's the failure mode
    /// this dialog is designed to avoid — "Continue Without" is a real, visible,
    /// bordered button, not grey small print. It also never repeats
    /// (`hasShownAnalyticsExplainer`), because continuous prompting is the other
    /// pattern those guidelines name.
    private var analyticsExplainer: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { dismissExplainer(enabling: false) }

            VStack(spacing: 18) {
                Image(systemName: "chart.bar.fill")
                    .font(.largeTitle)
                    .foregroundStyle(accent)

                Text("Help improve Allarise?")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                // Deliberately NOT pitched on alarm reliability — tying this to
                // "your alarm might fail" makes the ask sound like a warning
                // about the product. The case stands on its own: better
                // priorities, faster fixes.
                Text("Usage data shows which features people actually use, so development time goes to the parts that matter instead of guesswork. Crash reports flag problems automatically, so they get fixed sooner.\n\nIt's anonymous, never tied to you or your alarms, and never sold. You can turn it off anytime in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(onboardingSecondary(isDark))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    Button {
                        dismissExplainer(enabling: true)
                    } label: {
                        Text("Turn On")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(accent)

                    Button {
                        dismissExplainer(enabling: false)
                    } label: {
                        Text("Continue Without")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 340)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
            .padding(.horizontal, 28)
        }
        .accessibilityAddTraits(.isModal)
    }

    private func dismissExplainer(enabling: Bool) {
        if enabling { analyticsOptIn = true }
        withAnimation(.smooth(duration: 0.22)) { showAnalyticsExplainer = false }
        // Committing right after "Turn On" would race the toggle write, so pass
        // the decision through explicitly.
        persist(analytics: enabling ? true : analyticsOptIn)
    }

    // MARK: - Commit

    private func commit() {
        if !analyticsOptIn && !hasShownAnalyticsExplainer {
            hasShownAnalyticsExplainer = true
            UIAccessibility.post(notification: .announcement,
                                 argument: "Usage data and crash reports are optional. Choose Turn On or Continue Without.")
            withAnimation(.smooth(duration: 0.25)) { showAnalyticsExplainer = true }
            return
        }
        persist(analytics: analyticsOptIn)
    }

    private func persist(analytics: Bool) {
        settings.analyticsOptIn = analytics
        settings.productUpdatesOptIn = productUpdatesOptIn
        settings.hasAnsweredDataPreferences = true
        // Acts on the decision immediately: starts the backend on opt-in, or
        // stops AND purges on opt-out. Consent that only takes effect at next
        // launch isn't consent.
        Analytics.shared.refreshConsent()
        ProductUpdatePush.refreshConsent()
        WhatsNewStore.shared.refreshConsent()
        onDone()
    }

    // MARK: - Entrance

    private var cardTravel: CGFloat { reduceMotion ? 0 : 90 }
    private static let firstCardDelay: TimeInterval = 0.45
    /// Long enough to read the first card before the second arrives — see the
    /// matching constant in OnboardingView.
    private static let cardReadingGap: TimeInterval = 1.2

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
}
