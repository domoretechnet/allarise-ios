//
//  SupportPromptView.swift
//  HaWake Alarm V2
//
//  The periodic, always-dismissible "support the project" prompt for the free model.
//
//  Everything in Allarise is free. This is a gentle, non-blocking ask — Support, Share,
//  or Not Now — surfaced by `SupportPromptManager` after enough active-use days. It never
//  gates a feature (App Store Guideline 3.2.2): sharing and supporting only affect when
//  we ask again, never what the user can do. Closing it (button or swipe) always works.
//

import SwiftUI
import UIKit

struct SupportPromptView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { DeviceSettings.shared.appAccent(for: colorScheme) }

    /// Open the tip jar (support hub). The presenter decides how — typically after this
    /// sheet dismisses, to avoid stacking two sheets.
    let onSupport: () -> Void
    /// A share was actually completed (not cancelled) — extends the re-prompt window.
    let onShared: () -> Void
    /// The prompt was declined (Not Now, or swiped away) — shorter re-prompt window.
    let onDismiss: () -> Void

    @State private var showingShareSheet = false
    /// Set once the user takes an explicit action, so `onDisappear` doesn't also fire the
    /// dismiss handler on top of a support/share outcome. A bare swipe-away leaves it
    /// false, which correctly counts as a dismissal.
    @State private var didAct = false

    /// Prefilled, editable share message. The App Store link rides alongside as its own
    /// item so platforms that build a link preview (Messages, X, Threads) can.
    ///
    /// The single source of truth for the share copy: the Support section in Settings
    /// shares the app with the same message and link, so both stay in step.
    static let shareMessage = "Your alarm shouldn’t just wake you up—it should wake up your whole house. Meet Allarise, the free alarm app that connects to Home Assistant."

    private var shareText: String { Self.shareMessage }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image("AppIconDisplay")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 64 * 0.227, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    .padding(.top, 28)

                Text("Enjoying Allarise?")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                // fixedSize(vertical) lets the copy take all the height it needs instead of
                // being truncated with "…" when the sheet is at its shorter detent.
                Text("Allarise, and the features you love, are completely free — with no ads or unnecessary tracking. If Allarise helps you wake up, please consider supporting the project or sharing it with a friend. No pressure either way.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)

                VStack(spacing: 12) {
                    Button {
                        didAct = true
                        onSupport()
                        dismiss()
                    } label: {
                        Label("Support the Project", systemImage: "gift.fill")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)

                    Button {
                        showingShareSheet = true
                    } label: {
                        Label("Share with a Friend", systemImage: "square.and.arrow.up")
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                }
                .padding(.horizontal, 24)

                // Dismiss as a low-emphasis text link at the bottom — saves the vertical
                // space a full button took, and reads as the clearly-optional way out.
                Button {
                    didAct = true
                    onDismiss()
                    dismiss()
                } label: {
                    Text("Not Now")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .padding(.bottom, 24)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showingShareSheet) {
            ActivityShareSheet(items: [shareText, AppLinks.appStore]) { completed in
                showingShareSheet = false
                // Only a real, completed share earns the longer re-prompt window; a
                // cancel leaves the prompt's schedule untouched (iOS can't confirm an
                // actual public post — completion of the share sheet is the best signal).
                if completed {
                    didAct = true
                    onShared()
                    dismiss()
                }
            }
        }
        .onDisappear {
            // A swipe-to-dismiss (no button tapped) counts as "Not Now".
            if !didAct { onDismiss() }
        }
    }
}

/// `UIActivityViewController` wrapper that reports whether the share was completed vs
/// cancelled — `SwiftUI.ShareLink` gives no completion callback, and the re-prompt cadence
/// needs to distinguish a real share from a dismissed share sheet.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onComplete: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onComplete(completed)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#if DEBUG
/// Auto-presents the support prompt as its real sheet, for the `-supportPromptDebug`
/// launch arg — lets the prompt be screenshotted/reviewed without navigating Settings.
struct SupportPromptDebugHost: View {
    @State private var show = true
    var body: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
            .sheet(isPresented: $show) {
                SupportPromptView(onSupport: {}, onShared: {}, onDismiss: {})
            }
    }
}
#endif
