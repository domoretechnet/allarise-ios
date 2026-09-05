//
//  MemoryPressureMonitor.swift
//  HaWake Alarm V2
//
//  The app deliberately keeps itself resident overnight (BackgroundAudioKeepAlive)
//  so the in-app alarm Timer can fire. That makes jetsam — iOS terminating the
//  process under memory pressure — a direct threat to alarm reliability: a
//  jetsammed app loses the primary timer path and falls back to the AlarmKit
//  tiers, and the mission/UI layer is gone entirely.
//
//  Before this existed the app had NO memory-warning handling anywhere: no
//  observer, no cache dropping, and — most costly for diagnosis — no record
//  that pressure ever occurred. An unexplained overnight restart looked
//  identical to a force-quit in the logs.
//
//  This does two things: shed what is safely sheddable, and leave a footprint
//  in the exported log so "iOS killed us for memory" becomes a provable claim
//  rather than a guess.
//
//  TWO SOURCES, ON PURPOSE.
//
//  `UIApplication.didReceiveMemoryWarningNotification` is a UIKit-lifecycle
//  event and does not arrive while the app is backgrounded — which is the
//  entire window this monitor exists for. An app that only listens to it hears
//  nothing on the one night it gets jetsammed.
//
//  So a `DispatchSource` memory-pressure source is added alongside it. That one
//  is a kernel event delivered regardless of app state, at no cost while the
//  system is healthy: the source sits idle in the kernel and there is nothing
//  to poll. It is the strictly wider signal, so it — not the UIKit notification
//  — is what emits telemetry, otherwise a foreground warning would be counted
//  twice by two mechanisms firing for one event.
//
//  HEADROOM, NOT FOOTPRINT. The log records phys_footprint because that is what
//  jetsam measures, but the telemetry records `os_proc_available_memory()`:
//  how much is left before the limit. A footprint of 180 MB means nothing
//  without knowing the device's ceiling, whereas "12 MB remaining" means the
//  same thing on every device.
//

import Darwin
import Foundation
import UIKit

@MainActor
enum MemoryPressureMonitor {
    private static var observer: NSObjectProtocol?
    private static var pressureSource: DispatchSourceMemoryPressure?

    static func start() {
        startWarningObserver()
        startPressureSource()
    }

    // MARK: - Foreground: UIKit memory warning

    private static func startWarningObserver() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in handleWarning() }
        }
    }

    private static func handleWarning() {
        let footprint = currentFootprintMB()
        let detail = footprint.map { String(format: "%.0f MB", $0) } ?? "unknown"
        print("⚠️ Memory warning — footprint \(detail)")
        AppLogger.shared.log(
            "MEMORY WARNING received (footprint \(detail)) — purging caches. "
            + "If the app restarts shortly after this line, suspect jetsam.",
            category: .general
        )

        purgeSheddableCaches()
    }

    private static func purgeSheddableCaches() {
        // Favicons are the one unbounded-ish in-memory tier we own outright;
        // the disk tier survives, so this costs a re-read, not a re-download.
        Task.detached(priority: .utility) {
            await RadioFaviconCache.shared.purgeMemory()
        }

        // Wallpapers are downsampled at load and cached in an NSCache that the
        // system can evict on its own, but drop them explicitly too: a decoded
        // full-screen bitmap is the single largest reclaimable allocation the
        // app holds, and it re-decodes in milliseconds from the resized JPEG.
        DeviceSettings.invalidateWallpaperCache()

        // Other NSCache-backed caches (e.g. theme thumbnails) evict themselves.
    }

    // MARK: - Any state: kernel memory-pressure source

    /// Registers the kernel pressure source. Safe to call more than once.
    ///
    /// The source is retained for the process lifetime by design — there is no
    /// stop path, because the window this is watching is precisely the one
    /// where nothing else in the app is running to restart it.
    private static func startPressureSource() {
        guard pressureSource == nil else { return }

        // A utility-QoS queue rather than main: pressure can arrive while the
        // app is backgrounded and the main queue is the one thing that must not
        // be handed extra work at the moment iOS is deciding whether to kill us.
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler {
            // Read severity and headroom here, at the moment of the event.
            // By the time a main-actor hop completes, both have moved.
            let critical = source.data.contains(.critical)
            let availableMB = availableMemoryMB()
            Task { @MainActor in
                handlePressure(critical: critical, availableMB: availableMB)
            }
        }

        source.activate()
        pressureSource = source
    }

    private static func handlePressure(critical: Bool, availableMB: Int) {
        // `.background` specifically, not "not active": a pressure event during
        // a foreground transition is a different animal from one at 3 a.m. with
        // only the keep-alive audio session holding the process open.
        let wasBackground = UIApplication.shared.applicationState == .background
        let headroom = availableMB >= 0 ? "\(availableMB) MB free" : "headroom unknown"
        let footprint = currentFootprintMB().map { String(format: "%.0f MB", $0) } ?? "unknown"

        print("⚠️ Memory pressure — \(critical ? "CRITICAL" : "warning"), \(headroom)")
        AppLogger.shared.log(
            "MEMORY PRESSURE \(critical ? "CRITICAL" : "warning") "
            + "(\(headroom), footprint \(footprint), "
            + "\(wasBackground ? "backgrounded" : "foreground")) — purging caches. "
            + "A missing next line means jetsam won.",
            category: .general
        )

        Analytics.shared.log(.memoryPressure(critical: critical,
                                             availableMB: availableMB,
                                             wasBackground: wasBackground))

        purgeSheddableCaches()
    }

    /// Remaining headroom before this process hits its memory limit, in MB.
    ///
    /// Negative when the kernel can't answer — `os_proc_available_memory()`
    /// returns 0 both when the app is unbounded (debugger attached, some
    /// simulator configurations) and, in principle, when it is truly out of
    /// room. Reporting that 0 as "under 25 MB" would manufacture a critical
    /// reading out of a missing one, so it is passed through as invalid instead.
    nonisolated private static func availableMemoryMB() -> Int {
        let remaining = os_proc_available_memory()
        guard remaining > 0 else { return -1 }
        return Int(remaining / (1024 * 1024))
    }

    /// Resident footprint via task_vm_info, matching what jetsam actually
    /// measures. Nil if the kernel call fails.
    private static func currentFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / (1024 * 1024)
    }
}
