//
//  AppDelegate.swift
//  HaWake Alarm V2
//
//  Handles notification delivery and foreground alarm display
//

import UIKit
import UserNotifications
import AVFoundation
import BackgroundTasks

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    
    // MARK: - Orientation Lock
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .portrait
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        print("📱 applicationWillTerminate called")
        AppLogger.shared.log("applicationWillTerminate called", category: .general)
        
        // If an alarm is currently ringing, the backup alarm notification
        // (Tier 2) and AlarmKit ringing guard (Tier 3) handle recovery.
        // Don't send the generic "Oops" warning — it would be confusing
        // alongside the alarm-specific backup notification.
        let isAlarmRinging = AlarmSoundPlayer.shared.isPlaying
            || PendingAlarmStore.shared.pendingAlarm != nil
            || PendingAlarmStore.shared.hasPendingAlarm()

        // Dying with an alarm ringing or still to come is the leading indicator
        // of a missed alarm — recorded before the ringing early-return below so
        // the worse of the two cases isn't the one we lose.
        if isAlarmRinging || AppLifecycleMonitor.shared.hasActiveAlarmsForTermination {
            Analytics.shared.log(.terminatedWithAlarmPending(wasRinging: isAlarmRinging))
        }

        if isAlarmRinging {
            print("📱 Force-close notification: skipped (alarm is ringing — backup notification handles this)")
            return
        }

        // If an audio interruption is in progress (phone call, Siri, CarPlay, etc.),
        // iOS may terminate us to free resources for the interrupting app. This is NOT
        // the user closing the app — suppress the "Oops" warning so they don't see a
        // false alert while on a call.
        if BackgroundAudioKeepAlive.isAudioSessionInterrupted {
            print("📱 Force-close notification: skipped (audio session interrupted — likely a phone call)")
            AppLogger.shared.log("applicationWillTerminate: suppressed Oops notification (audio interrupted)", category: .general)
            return
        }

        // Mirrors scheduleForceCloseNotification's gate: with persistence Off —
        // or Dynamic while non-resident — suspension is the behaviour the user
        // chose and AlarmKit carries the alarms, so "re-open Allarise" would be
        // warning them about nothing.
        if !DeviceSettings.shared.keepAliveNeeded,
           !DeviceSettings.shared.forceCloseWarningDebugOverride {
            print("📱 Oops notification: skipped (App Persistence is off — suspension is expected)")
            return
        }

        let monitor = AppLifecycleMonitor.shared
        guard monitor.hasActiveAlarmsForTermination else { return }
        guard !DeviceSettings.shared.suppressBackgroundRefreshWarning else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Allarise was closed"
        content.body = "Alarms still ring at your ringtone volume. Re-open Allarise to restore Home Assistant commands."
        content.sound = .default
        content.categoryIdentifier = "APP_CLOSED_WARNING"
        content.interruptionLevel = .timeSensitive
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        let request = UNNotificationRequest(
            identifier: AppLifecycleMonitor.forceCloseNotificationID,
            content: content,
            trigger: trigger
        )
        
        let reminderContent = UNMutableNotificationContent()
        reminderContent.title = "Allarise is still closed"
        reminderContent.body = "Alarms still ring at ringtone volume, but Allarise won't respond to Home Assistant commands until it's re-opened."
        reminderContent.sound = .default
        reminderContent.categoryIdentifier = "APP_CLOSED_WARNING"
        reminderContent.interruptionLevel = .timeSensitive
        
        let reminderTrigger = UNTimeIntervalNotificationTrigger(timeInterval: 65, repeats: false)
        let reminderRequest = UNNotificationRequest(
            identifier: AppLifecycleMonitor.forceCloseReminderNotificationID,
            content: reminderContent,
            trigger: reminderTrigger
        )
        
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(
            withIdentifiers: [
                AppLifecycleMonitor.forceCloseNotificationID,
                AppLifecycleMonitor.forceCloseReminderNotificationID
            ]
        )
        center.add(request)
        center.add(reminderRequest)
        print("📱 Force-close notification: fired from applicationWillTerminate (5s + 65s reminder)")
    }
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        let pending = PendingAlarmStore.shared.pendingAlarm
        print("=== DIAG === applicationDidBecomeActive called, pendingAlarm=\(pending != nil ? "YES(\(pending!.label))" : "nil")")
        
        // If there's a pending alarm, ensure audio session is ready.
        // The actual alarm display is handled by AlarmWindowManager via didBecomeActiveNotification.
        if pending != nil {
            do {
                try AppAudioSession.setCategory(.playAndRecord, mode: .default, options: AppAudioSession.alarmFireCategoryOptions())
                try AppAudioSession.setActive(true)
                print("=== DIAG === Audio session reactivated in applicationDidBecomeActive")
            } catch {
                print("=== DIAG === FAILED to reactivate audio session: \(error)")
            }
        }
    }
    
    // MARK: - Remote Notifications (product updates only)

    // These two exist ONLY because `FirebaseAppDelegateProxyEnabled` is NO — see
    // the header of ProductUpdatePush.swift. With the proxy disabled, Messaging
    // never swizzles this class (which is also the alarm notification delegate),
    // so the APNs token has to be handed over by hand.
    //
    // Registration is only ever requested after the user opts into product
    // updates, so on most installs neither of these is ever called.
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        ProductUpdatePush.setAPNSToken(deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Non-fatal: announcements simply don't arrive. Alarms use local
        // notifications and AlarmKit and are unaffected.
        AppLogger.shared.log("Push: APNs registration failed — \(error.localizedDescription)", category: .general)
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        // Set notification center delegate
        UNUserNotificationCenter.current().delegate = self

        // Product-update push consent. Deliberately HERE and not in
        // `HaWake_Alarm_V2App.init`, where it used to live: the SwiftUI App's
        // init runs BEFORE this method (verified from launch logs — "App init
        // started" precedes "AppDelegate initialized"), so `enable()` was
        // calling `registerForRemoteNotifications()` before this delegate was
        // installed. iOS then took 13–30s to deliver the APNs token instead of
        // returning its cached one promptly, which in turn delayed the FCM
        // token and the topic subscribe. Registering after the delegate exists
        // is also what Apple's documentation asks for.
        //
        // Nothing about consent changes by moving it: this still reads
        // `productUpdatesOptIn` and does nothing at all when it is false, and
        // the toggle's own call sites (Settings, the data-preferences prompt)
        // are unaffected.
        ProductUpdatePush.refreshConsent()

        // Kick off iCloud probe, custom-sound migrations, and alarm-tone mirror
        // on a utility-priority background queue. Previously this ran inside
        // CustomSoundManager's static singleton init on the main thread and
        // could exceed the 20s launch watchdog on thermally-throttled devices
        // with pending iCloud downloads (0x8BADF00D crashes).
        CustomSoundManager.shared.bootstrap()

        // Configure notification categories with actions
        configureNotificationCategories()

        // Seed built-in wallpaper presets on first launch / app update
        DeviceSettings.shared.seedBuiltInPresetsIfNeeded()

        // NWS weather alerts are now DEBUG-only — disable for prod users who had it on.
        DeviceSettings.shared.disableNWSForProductionIfNeeded()

        // Decide once whether this install gets the "Weather Alerts Removed"
        // notice. Must run AFTER the migration above but is deliberately keyed on
        // its own flag: the migration may already have run in an earlier build,
        // and those users are precisely the ones whose alerts went away silently.
        NWSRemovalNotice.shared.latchEligibilityIfNeeded()

        // Pull NWS alert settings from iCloud KV store on a background thread.
        // Must happen AFTER DeviceSettings.shared is initialised (above) so the
        // singleton exists before the background task captures it.
        DeviceSettings.shared.syncNWSSettingsFromiCloud()

        #if DEBUG
        // Simulator harness: every other MQTT setting can be pre-seeded with
        // `simctl spawn <sim> defaults write`, but the credentials live only in
        // the Keychain, which defaults cannot reach. This writes them from a
        // launch argument so the sim can connect to the local test broker
        // without a manual trip through MQTT Settings:
        //   simctl launch booted <bundle-id> -seedMQTTCredentials <user> <pass>
        // Must run before syncMQTTCredentialsFromKeychain() below picks them up.
        if let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-seedMQTTCredentials") {
            let args = ProcessInfo.processInfo.arguments
            let user = args.count > idx + 1 ? args[idx + 1] : "debug"
            let pass = args.count > idx + 2 ? args[idx + 2] : "debug"
            KeychainHelper.shared.save(user, forKey: "mqttUsername")
            KeychainHelper.shared.save(pass, forKey: "mqttPassword")
        }
        #endif

        DeviceSettings.shared.syncMQTTCredentialsFromKeychain()

        // Register the BGAppRefreshTask handler. Must be called before the app
        // finishes launching (Apple requirement — cannot be deferred).
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundAudioKeepAlive.bgTaskIdentifier,
            using: nil
        ) { task in
            BackgroundAudioKeepAlive.shared.handleBackgroundRefreshTask(task as! BGAppRefreshTask)
        }

        // App Persistence at launch. The DynamicPersistenceController owns the
        // "should keep-alive run right now" decision for every mode: .on is
        // always resident, .dynamic is resident while charging / inside the
        // pre-alarm window, .off never. Its activate() → reevaluate() starts
        // keep-alive when needed and (re)submits the BGAppRefreshTask ladder —
        // which, under .dynamic, must be submitted even when keep-alive is NOT
        // starting (the whole point is being woken later).
        //
        // Skip the keep-alive start when an alarm is currently ringing at cold
        // launch (the controller's residency resolution treats a ringing alarm
        // as resident, but starting audio here would race the alarm's own
        // .playAndRecord configuration — see startAsync()'s own guards).
        // AlarmSound.stop() calls startAsync() once the alarm ends, so
        // keep-alive resumes naturally without racing.
        if PendingAlarmStore.shared.activeRingingAlarmID() != nil {
            print("📱 Background keep-alive: deferred (alarm is ringing — will resume after dismissal)")
            // Still submit the ladder so a suspended-later app gets its wake.
            BackgroundAudioKeepAlive.shared.scheduleBackgroundRefresh()
        } else {
            Task { @MainActor in
                DynamicPersistenceController.shared.activate()
            }
        }
        
        // Start NWS weather alert monitoring if enabled. DEBUG-only: the feature
        // is gated out of production (and force-disabled by a one-time migration).
        #if DEBUG
        // Note: nwsAlertsEnabled here is the value seeded from local UserDefaults.
        // syncNWSSettingsFromiCloud() resolves the authoritative iCloud value on a
        // background thread and re-arms the service if it differs.
        if DeviceSettings.shared.nwsAlertsEnabled {
            NWSAlertService.shared.start()
        }
        #endif

        // Check background refresh status
        BackgroundRefreshStatusChecker.shared.checkStatus()

        print("✅ AppDelegate initialized")
        AppLogger.shared.log("AppDelegate initialized", category: .general)
        return true
    }
    
    // MARK: - Notification Categories
    
    private func configureNotificationCategories() {
        // Category for background refresh warnings with action to open settings
        let openSettingsAction = UNNotificationAction(
            identifier: "OPEN_SETTINGS",
            title: "Open Settings",
            options: [.foreground]
        )

        let dismissAction = UNNotificationAction(
            identifier: "DISMISS_WARNING",
            title: "Dismiss",
            options: []
        )

        let warningCategory = UNNotificationCategory(
            identifier: "BACKGROUND_REFRESH_WARNING",
            actions: [openSettingsAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )

        // Category for MQTT alert notifications with dismiss action
        let dismissAlertAction = UNNotificationAction(
            identifier: "DISMISS_ALERT",
            title: "Dismiss",
            options: [.foreground]
        )

        let alertCategory = UNNotificationCategory(
            identifier: "MQTT_ALERT",
            actions: [dismissAlertAction],
            intentIdentifiers: [],
            options: []
        )

        // Category for app-closed warning — tapping opens the app
        let reopenAction = UNNotificationAction(
            identifier: "REOPEN_APP",
            title: "Open Allarise",
            options: [.foreground]
        )

        let closedCategory = UNNotificationCategory(
            identifier: "APP_CLOSED_WARNING",
            actions: [reopenAction],
            intentIdentifiers: [],
            options: []
        )

        // Category for backup alarm notification (Tier 2 recovery after force-close)
        let openAlarmAction = UNNotificationAction(
            identifier: "OPEN_ALARM",
            title: "Open Alarm",
            options: [.foreground]
        )

        let backupAlarmCategory = UNNotificationCategory(
            identifier: "ALARM_BACKUP",
            actions: [openAlarmAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            warningCategory,
            alertCategory,
            closedCategory,
            backupAlarmCategory
        ])

        print("✅ Notification categories configured")
    }
    
    // MARK: - Alert helpers

    /// Drop any pending-alarm state left behind by an alert that has already
    /// been resolved, so `checkAndShowPendingAlarm()` cannot present it on the
    /// next activation.
    ///
    /// Both clears are guarded on the alert's own id: the pending keys are the
    /// recovery signal for whatever alarm is pending, which may be a real alarm
    /// mid-snooze. An alert notification must never be able to clear that.
    private static func forgetPendingAlert(userInfo: [AnyHashable: Any]) {
        guard let alarmID = userInfo["alertAlarmID"] as? Int else { return }
        let store = PendingAlarmStore.shared
        store.clearPersistedPendingAlarm(ifAlarmID: alarmID)
        if store.pendingAlarm?.alarmID == alarmID {
            store.pendingAlarm = nil
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Called when notification is received while app is running (foreground or background)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let category = notification.request.content.categoryIdentifier
        
        // Background refresh warnings show as banner + sound
        if category == "BACKGROUND_REFRESH_WARNING" {
            completionHandler([.banner, .sound])
            return
        }
        
        // MQTT alerts: suppress notification when app is in foreground
        // (the alert screen is already shown directly by handleSecurityAlert)
        if category == "MQTT_ALERT" {
            completionHandler([])
            return
        }
        
        // App-closed warning: suppress if app is in foreground (it's not closed!)
        if category == "APP_CLOSED_WARNING" {
            completionHandler([])
            return
        }
        
        // Backup alarm notification: suppress if app is in foreground (alarm is already showing)
        if category == "ALARM_BACKUP" {
            Task { @MainActor in
                AppLogger.shared.log("Backup alarm notification suppressed (app in foreground)", category: .notification)
            }
            completionHandler([])
            return
        }

        // Product updates. Every alarm-related notification in this app is LOCAL,
        // so a push trigger means it came from FCM — and announcements are the
        // only thing we ever send. Without this they'd hit the catch-all below
        // and be silently swallowed whenever the app happened to be open.
        if notification.request.trigger is UNPushNotificationTrigger {
            // Arm the in-app banner from HERE too, not only from the activation
            // scan in `WhatsNewStore`. An announcement that arrives while the app
            // is already open never triggers that scan — `.task` has run and
            // `scenePhase` stays `.active` — so without this the banner would not
            // appear until the app was next backgrounded and reopened.
            let content = notification.request.content
            Task { @MainActor in
                WhatsNewStore.shared.ingest(
                    userInfo: content.userInfo,
                    title: content.title,
                    body: content.body
                )
            }
            completionHandler([.banner, .sound])
            return
        }

        // Suppress any other unexpected notifications
        completionHandler([])
    }
    
    /// Called when user taps notification
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let category = response.notification.request.content.categoryIdentifier

        // Product updates. Checked FIRST because it keys off the trigger type
        // rather than a category, and every branch below matches on a category
        // this notification does not have — without this it falls all the way
        // through to the bare completionHandler() and the announcement is
        // discarded, which is exactly what used to happen.
        //
        // Every alarm-related notification in this app is LOCAL, so a push
        // trigger means FCM, and announcements are the only thing we send.
        // Mirrors the same test in `willPresent` above.
        if response.notification.request.trigger is UNPushNotificationTrigger {
            let content = response.notification.request.content
            // Title and body are passed so the store can derive the SAME identity
            // it would from a delivered-notification scan — otherwise a tap and a
            // scan would disagree about which announcement this is, and the
            // banner would survive being read.
            Task { @MainActor in
                WhatsNewStore.shared.handleTap(
                    userInfo: content.userInfo,
                    title: content.title,
                    body: content.body
                )
                AppLogger.shared.log("What's New: product-update notification tapped", category: .notification)
            }
            completionHandler()
            return
        }

        // Handle background refresh warning action
        if category == "BACKGROUND_REFRESH_WARNING" {
            if response.actionIdentifier == "OPEN_SETTINGS" {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            completionHandler()
            return
        }
        
        // Handle backup alarm notification tap (Tier 2 recovery)
        if category == "ALARM_BACKUP" {
            let userInfo = response.notification.request.content.userInfo
            if let alarmID = userInfo["alarmID"] as? Int {
                let store = PendingAlarmStore.shared
                let label = userInfo["label"] as? String ?? "Alarm"
                let soundID = userInfo["soundID"] as? String ?? "Alarm_Clock"
                let volumeLevel = userInfo["volumeLevel"] as? Double
                
                // Restore pending alarm so checkAndShowPendingAlarm picks it up
                store.pendingAlarm = PendingAlarmStore.PendingAlarmInfo(
                    alarmID: alarmID,
                    label: label,
                    missionType: .none,  // Will be resolved from cached alarm data
                    soundID: soundID,
                    volumeLevel: volumeLevel
                )
                
                print("📱 Backup alarm notification tapped, restored pending alarm (id=\(alarmID))")
                Task { @MainActor in
                    AppLogger.shared.log("Backup alarm notification tapped: alarmID=\(alarmID) label=\(label)", category: .notification)
                }
            }
            completionHandler()
            return
        }
        
        // Handle MQTT alert notification tap
        if category == "MQTT_ALERT" {
            let content = response.notification.request.content
            let userInfo = content.userInfo
            let notificationID = response.notification.request.identifier
            let center = UNUserNotificationCenter.current()

            // Identity of the alert this notification is carrying. Newer
            // notifications carry it in userInfo; older ones (and anything sent
            // by a build that predates the ledger) have it re-derived from the
            // title and body, which are the same two strings the identity was
            // built from. Same for the delivery time: userInfo first, then the
            // notification's own date.
            let identities = AlertIdentity.identities(
                userInfo: userInfo,
                title: content.title,
                body: content.body
            )
            let deliveredAt = (userInfo[AlertDeliveryLedger.sentAtUserInfoKey] as? Double)
                .map(Date.init(timeIntervalSince1970:)) ?? response.notification.date

            // The notification's own "Dismiss" action resolves the alert. It
            // used to fall through to the restore below, which meant the
            // Dismiss button REOPENED the alert — the opposite of what it says.
            if response.actionIdentifier == "DISMISS_ALERT" {
                AlertDeliveryLedger.shared.markResolved(identities)
                center.removeDeliveredNotifications(withIdentifiers: [notificationID])
                Self.forgetPendingAlert(userInfo: userInfo)
                // If the alert window is actually up, dismiss it — but only when
                // the thing on screen IS this alert. `MQTTDismissAlarm` is heard
                // by every alarm screen, and dismissing a real ringing alarm
                // from a stale alert notification would be a serious failure.
                let dismissedAlarmID = userInfo["alertAlarmID"] as? Int
                Task { @MainActor in
                    let mgr = AlarmWindowManager.shared
                    if mgr.isShowingAlarm,
                       mgr.currentAlarm?.mission.type == .alert,
                       let dismissedAlarmID, mgr.currentAlarmID == dismissedAlarmID {
                        NotificationCenter.default.post(name: NSNotification.Name("MQTTDismissAlarm"), object: nil)
                    }
                    AppLogger.shared.log("MQTT alert notification dismissed from the notification action", category: .notification)
                }
                completionHandler()
                return
            }

            // Stale notification: this alert was already resolved AFTER this
            // notification arrived, so tapping it must not resurrect it. A
            // re-send of the same alert from Home Assistant is NOT caught here —
            // its notification is newer than the dismissal, so it opens normally.
            if AlertDeliveryLedger.shared.isResolved(anyOf: identities, deliveredAt: deliveredAt) {
                center.removeDeliveredNotifications(withIdentifiers: [notificationID])
                Self.forgetPendingAlert(userInfo: userInfo)
                print("🔕 MQTT alert notification tapped but the alert was already dismissed — not reopening")
                Task { @MainActor in
                    AppLogger.shared.log("MQTT alert notification tapped after dismissal — suppressed reopen", category: .notification)
                }
                completionHandler()
                return
            }

            if let alarmID = userInfo["alertAlarmID"] as? Int {
                let store = PendingAlarmStore.shared

                // Fill in the alert text from the notification if the stored
                // copy is gone (a very old alert, or a UserDefaults blob that
                // did not survive). Never overwrites what the alert itself
                // stored. Without this the alert screen would show a title and
                // no message, and the dismissal that follows would compute a
                // content identity that matches nothing.
                if store.retrieveAlertInfo(alarmID: alarmID) == nil {
                    store.storeAlertInfo(alarmID: alarmID, title: content.title, message: content.body)
                }

                // Restore pending alarm from notification userInfo
                let soundID = userInfo["soundID"] as? String ?? "Alarm_Clock"
                let volumeLevel = userInfo["volumeLevel"] as? Double
                let playSound = userInfo["playSound"] as? Bool ?? true
                
                store.pendingAlarm = PendingAlarmStore.PendingAlarmInfo(
                    alarmID: alarmID,
                    label: response.notification.request.content.title,
                    missionType: .alert,
                    soundID: playSound ? soundID : "silent",
                    volumeLevel: volumeLevel
                )
                
                // The app lifecycle (checkAndShowPendingAlarm) will pick this up
                // when scenePhase becomes .active
                print("🔔 MQTT alert notification tapped, restored pending alarm (id=\(alarmID))")
                Task { @MainActor in
                    AppLogger.shared.log("MQTT alert notification tapped: alarmID=\(alarmID)", category: .notification)
                }
            }
            completionHandler()
            return
        }

        // Handle NWS alert notification tap (same flow as MQTT alert)
        if category == "NWS_ALERT" {
            let userInfo = response.notification.request.content.userInfo
            if let alarmID = userInfo["alertAlarmID"] as? Int {
                let store = PendingAlarmStore.shared
                let soundID = userInfo["soundID"] as? String ?? "Alarm_Clock"
                let volumeLevel = userInfo["volumeLevel"] as? Double

                store.pendingAlarm = PendingAlarmStore.PendingAlarmInfo(
                    alarmID: alarmID,
                    label: response.notification.request.content.title,
                    missionType: .alert,
                    soundID: soundID,
                    volumeLevel: volumeLevel
                )

                print("🔔 NWS alert notification tapped, restored pending alarm (id=\(alarmID))")
                Task { @MainActor in
                    AppLogger.shared.log("NWS alert notification tapped: alarmID=\(alarmID)", category: .notification)
                }
            }
            completionHandler()
            return
        }

        completionHandler()
    }
}
