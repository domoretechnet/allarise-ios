//
//  StatusBarStyleController.swift
//  HaWake Alarm V2
//
//  Forces the system status bar (the time / battery text in the safe area above
//  the app) to a chosen style independent of the app's color scheme.
//
//  Why this exists
//  ---------------
//  SwiftUI's WindowGroup only exposes `.preferredColorScheme`, which flips the
//  *entire* app appearance — there is no supported "just the status bar" knob.
//  Some home themes ship a dark light-mode wallpaper (Terminal Drift, Ember
//  Tide, …) where SwiftUI's default black status-bar text is unreadable. To make
//  only the status bar white for those themes while the rest of light mode stays
//  light, we override the root hosting controller's `preferredStatusBarStyle`.
//
//  Scope and safety
//  ----------------
//  The override is installed once, on the *exact runtime class* of the key
//  window's root view controller (the WindowGroup's `UIHostingController`
//  specialization). We do not touch `UIViewController` or `UIHostingController`
//  broadly, so unrelated screens — alarm full-screen covers, notification
//  content controllers, share sheets — keep their own status-bar behavior. When
//  the override is nil the original (color-scheme-derived) implementation runs
//  unchanged, so removing the flag fully restores default behavior.
//

import UIKit
import ObjectiveC.runtime

@MainActor
final class StatusBarStyleController {
    static let shared = StatusBarStyleController()

    /// When non-nil, the root status bar uses this style regardless of the app's
    /// color scheme. nil restores the system-derived (color-scheme) default.
    private(set) var override: UIStatusBarStyle?

    private var didInstall = false

    private init() {}

    /// Set (or clear, with nil) the forced status-bar style. Installs the
    /// root-controller override lazily on first use, then requests a refresh.
    func setOverride(_ style: UIStatusBarStyle?) {
        guard override != style else { return }
        override = style
        installIfNeeded()
        rootViewController?.setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: - Internals

    private var rootViewController: UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?
            .rootViewController
    }

    /// Add a `preferredStatusBarStyle` getter to the root controller's exact
    /// class that consults `override`, falling back to the inherited
    /// implementation when no override is set. Idempotent.
    private func installIfNeeded() {
        guard !didInstall, let root = rootViewController else { return }
        let cls: AnyClass = type(of: root)
        let sel = #selector(getter: UIViewController.preferredStatusBarStyle)

        // The inherited implementation (SwiftUI's, derived from the color
        // scheme). Captured before we add our own so the nil-override path can
        // call straight through to it without recursing.
        let inheritedIMP = class_getMethodImplementation(cls, sel)
        typealias Getter = @convention(c) (AnyObject, Selector) -> UIStatusBarStyle
        let inherited = unsafeBitCast(inheritedIMP, to: Getter.self)

        let block: @convention(block) (AnyObject) -> UIStatusBarStyle = { obj in
            if let forced = StatusBarStyleController.shared.override {
                return forced
            }
            return inherited(obj, sel)
        }
        let newIMP = imp_implementationWithBlock(block)

        // `q@:` — Int (NSInteger) return, self + _cmd. Adds the method to `cls`
        // only when it does not already define its own; otherwise we replace the
        // existing one in place. Either way the change is scoped to `cls`.
        if !class_addMethod(cls, sel, newIMP, "q@:") {
            if let method = class_getInstanceMethod(cls, sel) {
                method_setImplementation(method, newIMP)
            }
        }
        didInstall = true
    }
}
