//
//  ProPaywallView.swift
//  HaWake Alarm V2
//
//  Created by Bryan on 3/12/26.
//

import SwiftUI
import StoreKit

/// State-aware "Allarise Pro" hub. The same screen handles every entitlement state:
/// purchasing (not Pro), managing/upgrading (monthly subscriber), and confirmation
/// (lifetime owner or complimentary/early adopter). Opened from Settings in all states.
struct ProPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { DeviceSettings.shared.appAccent(for: colorScheme) }
    @Bindable var storeManager: StoreManager

    @State private var isProcessingPurchase = false
    @State private var showingPurchaseError = false
    @State private var purchaseErrorMessage = ""
    @State private var isRetryingLoad = false
    @State private var showingRedeemCode = false
    @State private var showingManageSubscriptions = false
    @State private var showingCancelSubPrompt = false
    @State private var showingTipThanks = false

    // MARK: - Entitlement state

    private var ownsLifetime: Bool {
        storeManager.purchasedProductIDs.contains(StoreManager.lifetimeID)
    }
    private var isSubscriber: Bool {
        storeManager.purchasedProductIDs.contains(StoreManager.monthlyID)
    }
    /// Pro without a purchase on this account — early adopter or Debug force-pro.
    private var isComplimentary: Bool {
        storeManager.effectiveIsPro && !ownsLifetime && !isSubscriber
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    headerSection

                    // Existing subscriber: a short note that everything's free and they can
                    // manage/cancel anytime (nothing is lost by cancelling).
                    if isSubscriber && !ownsLifetime {
                        subscriberManageNote
                    }
                    // Owns lifetime AND still subscribed monthly — nudge to cancel the sub.
                    if ownsLifetime && isSubscriber {
                        dualSubscriptionSection
                    }

                    // One-time options: the tip tiers and the lifetime, together, minus
                    // anything already owned. Shown to everyone who has an option left.
                    oneTimeSupportSection

                    // Monthly support: only offered to those not already subscribed, and
                    // not to lifetime owners (who've already given a one-time contribution).
                    if !isSubscriber && !ownsLifetime {
                        monthlySupportSection
                    }

                    // Subscription disclosure is only required while the monthly option is
                    // actually on screen; otherwise just the Terms/Privacy links.
                    if !isSubscriber && !ownsLifetime {
                        legalFooter
                    } else {
                        termsAndPrivacy
                    }

                    // Restore: long, centered, below the disclosure. Only before owning
                    // Pro outright (redundant on lifetime/complimentary screens).
                    if !ownsLifetime && !isComplimentary {
                        restoreButton
                    }
                }
            }
            .offerCodeRedemption(isPresented: $showingRedeemCode) { result in
                // listenForTransactions() also catches this via Transaction.updates.
                if case .success = result {
                    Task {
                        await storeManager.updatePurchasedProducts()
                        if storeManager.effectiveIsPro { dismiss() }
                    }
                }
            }
            // Intercept the inline "Manage your plan" link; everything else (Terms /
            // Privacy) opens normally in the browser.
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "manage" {
                    showingManageSubscriptions = true
                    return .handled
                }
                return .systemAction
            })
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(storeManager.effectiveIsPro ? "Done" : "Cancel") { dismiss() }
                }
                // Redeem Code top-right, by Cancel — subscription offer codes only.
                if !ownsLifetime && !isComplimentary {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Redeem Code") { showingRedeemCode = true }
                    }
                }
            }
            .alert("Purchase Error", isPresented: $showingPurchaseError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(purchaseErrorMessage)
            }
            .alert("Thank You! 💛", isPresented: $showingTipThanks) {
                Button("You're Welcome", role: .cancel) {}
            } message: {
                Text("Your support means a lot and helps keep Allarise going. Everything in the app stays free.")
            }
            .alert("Thank You! 💛", isPresented: $showingCancelSubPrompt) {
                Button("Manage Subscription") { showingManageSubscriptions = true }
                Button("Later", role: .cancel) { }
            } message: {
                Text("You've given a one-time contribution. Since you're also subscribed monthly, you may want to cancel that so you're not charged again — nothing in the app is ever locked either way.")
            }
            .manageSubscriptionsSheet(isPresented: $showingManageSubscriptions)
            .onChange(of: showingManageSubscriptions) { wasShowing, isShowing in
                // When the system manage-subscriptions sheet is dismissed (Done), close
                // the Pro hub too so the user lands back on the main Settings page.
                if wasShowing && !isShowing { dismiss() }
            }
            .task {
                if storeManager.products.isEmpty {
                    retryLoadProducts()
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder private var headerSection: some View {
        VStack(spacing: 12) {
            Image("AppIconDisplay")
                .resizable()
                .scaledToFit()
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 76 * 0.227, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                .padding(.top, 32)

            Text(storeManager.effectiveIsPro ? "Allarise Pro" : "Support Allarise")
                .font(.title2.bold())

            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.bottom, 32)
    }

    /// Markdown so the subscriber line can carry an inline "Manage your plan" link
    /// (the `manage://plan` scheme is intercepted in `body` to open the manage sheet).
    private var headerSubtitle: AttributedString {
        let md: String
        if ownsLifetime {
            md = "Thank you for supporting Allarise! Every feature is yours to enjoy."
        } else if isSubscriber {
            md = "Thanks for supporting Allarise monthly. [Manage your plan](manage://plan) or switch to a one-time option below."
        } else if isComplimentary {
            md = "You have complimentary access as an early supporter — thank you! Support our continued development by making an optional contribution below."
        } else {
            md = "Allarise is free but we need help keeping things running. If this app has helped you wake up, please consider making an optional one-time contribution to help support our continued development."
        }
        return (try? AttributedString(markdown: md)) ?? AttributedString(md)
    }

    /// Short label for a one-time option chip. The lifetime's live StoreKit display name is
    /// long ("HaWake Pro – Lifetime"), so it gets a compact "Lifetime" in the grid; tips
    /// use their own short display names.
    private func oneTimeLabel(for product: Product) -> String {
        product.id == StoreManager.lifetimeID ? "Lifetime" : product.displayName
    }

    /// "Leave a One-Time Tip" — the tip tiers and the lifetime together, as price chips,
    /// sorted by price and excluding anything already owned. Shows a loader/retry while
    /// StoreKit is still fetching; renders nothing once every one-time option is owned.
    @ViewBuilder private var oneTimeSupportSection: some View {
        let options = storeManager.oneTimeSupportProducts
        if !options.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Make a One-Time Contribution")
                    .font(.headline)
                Text("Give once to help keep Allarise running — any amount is appreciated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(options, id: \.id) { product in
                        let featured = product.id == StoreManager.lifetimeID
                        TipTierButton(
                            title: oneTimeLabel(for: product),
                            price: product.displayPrice,
                            accent: accent,
                            isLoading: isProcessingPurchase,
                            badge: featured ? "Most Popular" : nil,
                            isFeatured: featured
                        ) { handlePurchase(product) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 20)
            .disabled(isProcessingPurchase)
        } else if storeManager.products.isEmpty {
            // Products haven't loaded yet (or failed) — offer a retry rather than an empty
            // section. On device this is also what shows until the tip IDs exist in ASC.
            VStack(spacing: 12) {
                if isRetryingLoad {
                    ProgressView()
                    Text("Loading options…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Couldn't load support options.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") { retryLoadProducts() }
                        .font(.subheadline)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    /// "Support Us Monthly" — the recurring option, on its own. No free trial (there's
    /// nothing to trial in a free app). Prices come live from StoreKit.
    @ViewBuilder private var monthlySupportSection: some View {
        if let monthly = storeManager.monthlyProduct {
            VStack(alignment: .leading, spacing: 12) {
                Text("Support Us Monthly")
                    .font(.headline)

                PurchaseOptionCard(
                    title: "Monthly Supporter",
                    badge: nil,
                    price: monthly.displayPrice,
                    period: "/ month",
                    detail: "Renews monthly until cancelled.",
                    isLoading: isProcessingPurchase,
                    isProminent: true
                ) { handlePurchase(monthly) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 20)
            .disabled(isProcessingPurchase)
        }
    }

    /// Existing monthly subscriber: reassure that everything is free and give an easy path
    /// to manage/cancel. (One-time options still appear below via `oneTimeSupportSection`.)
    @ViewBuilder private var subscriberManageNote: some View {
        VStack(spacing: 10) {
            Text("You're supporting Allarise monthly — thank you! Everything in the app is free, so you can cancel anytime without losing anything.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Manage Subscription") { showingManageSubscriptions = true }
                .font(.subheadline)
        }
        .padding(.bottom, 20)
    }

    /// Shown only when the user owns Pro outright AND still has an active monthly
    /// subscription (double-billing). Surfaces a cancel path so they aren't charged.
    @ViewBuilder private var dualSubscriptionSection: some View {
        VStack(spacing: 12) {
            Text("You also have an active monthly subscription. Since you already own Pro, cancel it so you're not charged again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Manage Subscription") { showingManageSubscriptions = true }
                .font(.subheadline)
        }
        .padding(.bottom, 24)
    }

    /// Long, centered Restore button, shown below the disclosure for non-Pro and
    /// subscriber states. (Redeem Code lives in the toolbar; offer codes apply to the
    /// subscription only, so it's hidden for lifetime/complimentary users.)
    @ViewBuilder private var restoreButton: some View {
        Button("Restore Purchases") { restorePurchases() }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 32)
            .disabled(isProcessingPurchase)
    }

    /// Non-Pro footer: the required subscription disclosure with Terms of Use and
    /// Privacy Policy folded in as inline links — one compact block instead of three
    /// stacked ones, while still satisfying Guideline 3.1.2(c). No trial to disclose.
    @ViewBuilder private var legalFooter: some View {
        Text("The monthly option auto-renews at the listed price until cancelled. [Terms of Use](\(AppLinks.termsString)) · [Privacy Policy](\(AppLinks.privacyString))")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .tint(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .padding(.top, 14)
            .padding(.bottom, 12)
    }

    /// Pro states: just the Terms / Privacy links (no subscription disclosure needed).
    @ViewBuilder private var termsAndPrivacy: some View {
        HStack(spacing: 16) {
            Link("Terms of Use", destination: AppLinks.terms)
            Link("Privacy Policy", destination: AppLinks.privacy)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.top, 12)
        .padding(.bottom, 32)
    }

    // MARK: - Actions

    private func handlePurchase(_ product: Product) {
        AppLogger.shared.log("Paywall: purchase tapped for \(product.id)", category: .general)
        Analytics.shared.log(.purchaseStarted)
        isProcessingPurchase = true
        Task {
            do {
                let transaction = try await storeManager.purchase(product)
                isProcessingPurchase = false

                // A returned transaction is NOT proof of an active entitlement — a
                // previously-cancelled/expired subscription can return a transaction yet
                // grant nothing. Gate on the real entitlement state (currentEntitlements,
                // which purchase() refreshed) so we never close the paywall pretending
                // Pro is active when it isn't.
                let nowPro = storeManager.effectiveIsPro
                AppLogger.shared.log("Paywall: purchase(\(product.id)) txn=\(transaction != nil), effectiveIsPro=\(nowPro)", category: .general)

                if transaction == nil {
                    // User cancelled or the purchase is pending (Ask to Buy) — stay put.
                    return
                }

                // A tip grants no entitlement, so the Pro-activation checks below don't
                // apply. It's still a completed support action (hasSupported is set in
                // StoreManager) — thank the user and let them stay to give again.
                if StoreManager.tipIDs.contains(product.id) {
                    Analytics.shared.log(.purchaseCompleted)
                    showingTipThanks = true
                    return
                }

                // Subscriber who just gave the one-time lifetime: don't dismiss — nudge them
                // to cancel the monthly so they aren't double-charged (Apple won't auto-cancel).
                if product.id == StoreManager.lifetimeID && isSubscriber {
                    Analytics.shared.log(.purchaseCompleted)
                    showingCancelSubPrompt = true
                    return
                }

                if nowPro {
                    Analytics.shared.log(.purchaseCompleted)
                    dismiss()
                } else {
                    // Rare: completed but entitlement not reflected yet. Auto-sync with
                    // the App Store (what tapping Restore does) and re-check before
                    // bothering the user.
                    AppLogger.shared.log("Paywall: not entitled after purchase — auto-restoring…", category: .general)
                    await storeManager.restorePurchases()
                    if storeManager.effectiveIsPro {
                        Analytics.shared.log(.purchaseCompleted)
                        dismiss()
                    } else {
                        purchaseErrorMessage = "The purchase completed but Pro isn't active yet. If you previously cancelled this subscription it may need to renew — try again, or use Restore Purchases."
                        showingPurchaseError = true
                    }
                }
            } catch {
                isProcessingPurchase = false
                AppLogger.shared.log("Paywall: purchase(\(product.id)) error — \(error.localizedDescription)", category: .general)
                purchaseErrorMessage = error.localizedDescription
                showingPurchaseError = true
            }
        }
    }

    private func retryLoadProducts() {
        isRetryingLoad = true
        Task {
            await storeManager.loadProducts()
            isRetryingLoad = false
        }
    }

    private func restorePurchases() {
        isProcessingPurchase = true
        Task {
            await storeManager.restorePurchases()
            isProcessingPurchase = false
            // Don't auto-dismiss here — the user opened the hub deliberately and may
            // want to keep managing.
        }
    }
}

// MARK: - Purchase Option Card

private struct PurchaseOptionCard: View {
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { DeviceSettings.shared.appAccent(for: colorScheme) }
    let title: String
    let badge: String?
    let price: String
    let period: String
    let detail: String
    let isLoading: Bool
    let isProminent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(isProminent ? .white : .primary)
                    if let badge {
                        Text(badge)
                            .font(.caption.bold())
                            .foregroundStyle(isProminent ? accent : .white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(isProminent ? Color.white : accent, in: Capsule())
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isProminent ? .white.opacity(0.8) : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(price)
                        .font(.title3.bold())
                        .foregroundStyle(isProminent ? .white : .primary)
                        .fixedSize()
                    Text(period)
                        .font(.caption)
                        .foregroundStyle(isProminent ? .white.opacity(0.8) : .secondary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background {
                if isProminent {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(accent)
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color(.separator), lineWidth: 0.5)
                        )
                }
            }
            // Make the entire card (incl. padding) a tap target, not just the text/icons.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tip Tier Button

/// Compact price chip for a one-time tip tier. Shows the price prominently and the tier
/// name beneath. Prices come live from StoreKit. A `featured` chip fills with the accent
/// and carries a small badge (e.g. "Most Popular") to steer choice toward the lifetime.
private struct TipTierButton: View {
    let title: String
    let price: String
    let accent: Color
    let isLoading: Bool
    var badge: String? = nil
    var isFeatured: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if let badge {
                    Text(badge.uppercased())
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(0.5)
                        .foregroundStyle(isFeatured ? .white : accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(price)
                    .font(.title3.bold())
                    .foregroundStyle(isFeatured ? .white : accent)
                    .fixedSize()
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(isFeatured ? .white.opacity(0.85) : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isFeatured ? accent : Color(.secondarySystemGroupedBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(accent.opacity(isFeatured ? 0 : 0.35), lineWidth: 1)
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isLoading ? 0.5 : 1)
    }
}

#if DEBUG
// MARK: - Support screen preview (DEBUG)

/// A StoreKit-free preview of the redesigned support screen, driven by the `-supportDebug`
/// launch arg. It reuses the real leaf components (`TipTierButton`, `PurchaseOptionCard`)
/// with static tier data, so the full tip jar — all five tips plus the featured Lifetime —
/// renders on a plain simulator or device without needing products loaded from App Store
/// Connect. Buttons are inert; this is for visual review and App Store review screenshots.
struct SupportPreviewMockHost: View {
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { DeviceSettings.shared.appAccent(for: colorScheme) }

    /// (title, price, isFeatured, badge) in the same price order the real screen uses.
    private let oneTime: [(String, String, Bool, String?)] = [
        ("Snooze",         "$0.99",  false, nil),
        ("Early Bird",     "$2.99",  false, nil),
        ("Lifetime",       "$6.99",  true,  "Most Popular"),
        ("Morning Person",   "$9.99",  false, nil),
        ("Sunrise Champion", "$19.99", false, nil),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 12) {
                        Image("AppIconDisplay")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 76, height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 76 * 0.227, style: .continuous))
                            .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                            .padding(.top, 32)
                        Text("Support Allarise")
                            .font(.title2.bold())
                        Text("Allarise is free but we need help keeping things running. If this app has helped you wake up, please consider making an optional one-time contribution to help support our continued development.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .padding(.bottom, 32)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Make a One-Time Contribution")
                            .font(.headline)
                        Text("Give once to help keep Allarise running — any amount is appreciated.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(oneTime, id: \.0) { tier in
                                TipTierButton(
                                    title: tier.0,
                                    price: tier.1,
                                    accent: accent,
                                    isLoading: false,
                                    badge: tier.3,
                                    isFeatured: tier.2
                                ) {}
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Support Us Monthly")
                            .font(.headline)
                        PurchaseOptionCard(
                            title: "Monthly Supporter",
                            badge: nil,
                            price: "$0.99",
                            period: "/ month",
                            detail: "Renews monthly until cancelled.",
                            isLoading: false,
                            isProminent: true
                        ) {}
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Support (Preview)")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
