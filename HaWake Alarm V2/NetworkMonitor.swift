//
//  NetworkMonitor.swift
//  HaWake Alarm V2
//
//  Monitors network connectivity and detects home WiFi SSIDs
//  Used to switch between internal/external MQTT brokers
//

import Foundation
import Network
import NetworkExtension
import CoreLocation
import Observation
import UIKit

@MainActor
@Observable
final class NetworkMonitor: NSObject, CLLocationManagerDelegate {
    static let shared = NetworkMonitor()
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.hawake.networkmonitor")
    private var locationManager: CLLocationManager!
    
    private(set) var isConnected = false
    private(set) var connectionType: NWInterface.InterfaceType?
    private(set) var currentSSID: String?
    private(set) var isOnHomeNetwork = false
    private(set) var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    /// True once the first network path update has been processed and SSID resolved (if on WiFi).
    private(set) var hasResolvedInitialNetwork = false

    /// Monotonic token bumped on every network-path change. Async SSID resolution that
    /// started under an older token is discarded, so a slow/stale fetch can't clobber a
    /// newer network state — the root of cellular↔Wi-Fi flapping / wrong final state.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pathContinuation: AsyncStream<Network.NWPath>.Continuation?
    @ObservationIgnored private var pathConsumerTask: Task<Void, Never>?
    
    private override init() {
        super.init()
        let manager = CLLocationManager()
        manager.delegate = self
        self.locationManager = manager
        self.locationAuthorizationStatus = manager.authorizationStatus
        print("📍 [NetworkMonitor] CLLocationManager created, status: \(manager.authorizationStatus.rawValue)")
        startMonitoring()

        // iOS only answers SSID requests while the app is FOREGROUND (with
        // When-In-Use location) — the background keep-alive keeps the process
        // running but the app state is still .background, so background reads
        // are denied by nehelper. Re-resolve on every foreground, where the
        // read reliably succeeds, and auto-prompt for the location permission
        // when SSID-based broker switching is configured but never authorized.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if DeviceSettings.shared.mqttEnabled,
                   !DeviceSettings.shared.homeSSIDs.isEmpty,
                   self.isLocationNotDetermined {
                    self.requestLocationPermission()
                }
                self.refreshOnForeground()
            }
        }
    }
    
    /// True when location is denied/restricted — SSID detection can't work until the
    /// user enables location for the app in Settings.
    var isLocationDenied: Bool {
        locationAuthorizationStatus == .denied || locationAuthorizationStatus == .restricted
    }

    /// True when the user hasn't yet been asked for location permission.
    var isLocationNotDetermined: Bool {
        locationAuthorizationStatus == .notDetermined
    }

    /// Request location permission needed for WiFi SSID detection
    func requestLocationPermission() {
        let status = locationManager.authorizationStatus
        print("📍 [NetworkMonitor] requestLocationPermission called, current status: \(status.rawValue) (0=notDetermined, 1=restricted, 2=denied, 3=authorizedAlways, 4=authorizedWhenInUse)")
        if status == .notDetermined {
            print("📍 [NetworkMonitor] Calling requestWhenInUseAuthorization()...")
            locationManager.requestWhenInUseAuthorization()
        } else {
            print("📍 [NetworkMonitor] Permission already determined, not requesting")
        }
    }
    
    // MARK: - CLLocationManagerDelegate
    
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        print("📍 [NetworkMonitor] locationManagerDidChangeAuthorization: \(status.rawValue)")
        Task { @MainActor in
            self.locationAuthorizationStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                print("📍 [NetworkMonitor] Permission granted! Refreshing SSID...")
                await self.resolveSSID(generation: self.generation)
                // Now that the SSID may be available, re-notify so MQTTManager can pick
                // the correct (home/internal) broker.
                NotificationCenter.default.post(name: NSNotification.Name("NetworkChanged"), object: nil)
            }
        }
    }
    
    func startMonitoring() {
        // Funnel path updates through an AsyncStream consumed by a SINGLE ordered task,
        // so each update is fully processed (including the awaited SSID resolution)
        // before the next. Wrapping each update in its own Task — as before — let the
        // slow SSID fetch suspend and a later update interleave, which could leave the
        // cellular↔Wi-Fi state wrong. bufferingNewest(1) means that if updates pile up
        // while we're resolving, we only act on the latest (current) network state.
        let (stream, continuation) = AsyncStream<Network.NWPath>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pathContinuation = continuation
        monitor.pathUpdateHandler = { path in
            continuation.yield(path)
        }
        monitor.start(queue: queue)

        pathConsumerTask = Task { @MainActor [weak self] in
            for await path in stream {
                await self?.handlePath(path)
            }
        }
    }

    func stopMonitoring() {
        monitor.cancel()
        pathContinuation?.finish()
        pathConsumerTask?.cancel()
    }

    /// Processes a single network path to final state, then notifies observers once.
    /// Runs sequentially (one path at a time) on the consumer task.
    @MainActor
    private func handlePath(_ path: Network.NWPath) async {
        generation &+= 1
        let gen = generation

        isConnected = path.status == .satisfied

        if path.usesInterfaceType(.wifi) {
            connectionType = .wifi
            // Resolve the SSID (with retries) before notifying, so the first
            // NetworkChanged already reflects home/external — no broker flapping.
            await resolveSSID(generation: gen)
        } else if path.usesInterfaceType(.cellular) {
            connectionType = .cellular
            currentSSID = nil
            isOnHomeNetwork = false
        } else if path.usesInterfaceType(.wiredEthernet) {
            connectionType = .wiredEthernet
            currentSSID = nil
            // Assume wired ethernet at home is "home network"
            isOnHomeNetwork = true
        } else {
            connectionType = nil
            currentSSID = nil
            isOnHomeNetwork = false
        }

        // A newer path update superseded this one mid-resolve — let the newer one win.
        guard gen == generation else { return }

        let brokerSide = isOnHomeNetwork ? "home/internal" : "external"
        print("🌐 Network changed: \(connectionDescription)")
        AppLogger.shared.log(
            "Network changed [gen \(gen)]: \(connectionDescription) → \(brokerSide), SSID: \(currentSSID ?? "nil")",
            category: .network
        )

        let wasInitialResolve = !hasResolvedInitialNetwork
        hasResolvedInitialNetwork = true

        // Notify observers (e.g. MQTTManager) now that SSID is resolved, so
        // getBrokerConfig returns the correct home/external broker.
        NotificationCenter.default.post(name: NSNotification.Name("NetworkChanged"), object: nil)

        if wasInitialResolve {
            print("🌐 [NetworkMonitor] Initial network resolved: \(connectionDescription)")
        }
    }
    
    /// Resolves the current WiFi SSID for a given network `generation`, with retries to
    /// cover the brief nil window right after Wi-Fi associates (or a VPN toggle).
    /// Requires Location "When In Use". All writes are guarded by the generation token:
    /// if a newer network change has bumped `generation`, this stale resolution aborts
    /// without clobbering current state.
    @MainActor
    private func resolveSSID(generation gen: Int) async {
        let maxAttempts = 3
        for attempt in 0..<maxAttempts {
            let network = await NEHotspotNetwork.fetchCurrent()
            guard gen == generation else { return }   // superseded by a newer network change

            if let ssid = network?.ssid {
                currentSSID = ssid
                checkIfHomeNetwork(ssid)
                print("📶 [NetworkMonitor] Connected to WiFi: \(ssid)")
                return
            }

            // Temporary nil — retry only while still on Wi-Fi (no point retrying on
            // cellular/ethernet, where the SSID is legitimately unavailable).
            guard connectionType == .wifi, attempt < maxAttempts - 1 else { break }
            print("⚠️ [NetworkMonitor] SSID nil on WiFi (attempt \(attempt + 1)), retrying…")
            try? await Task.sleep(for: .seconds(1.5))
            guard gen == generation else { return }
        }

        guard gen == generation else { return }

        // SSID unreadable. While the app is backgrounded, iOS DENIES the SSID
        // request outright (nehelper result code 1) even though the keep-alive
        // keeps us running — an unreadable SSID is NO INFORMATION, not evidence
        // we left home.
        //
        // Ground truth instead: probe the internal MQTT broker over TCP (bare
        // handshake — no MQTT packet, no credentials). Works in the
        // background, needs no permissions.
        //
        // SECURITY: the probe is CONFIRM-OR-DOWNGRADE ONLY. It never upgrades
        // external → internal, because a "something answered on that port"
        // signal on an unverified network must not cause the real MQTT client
        // to send credentials there (internal connections may be plain TCP).
        // Internal mode is only ever entered via a foreground SSID match;
        // the probe can merely (a) confirm a previously-confirmed home
        // network is still valid, or (b) downgrade to external when the
        // internal broker is gone (left home for another Wi-Fi).
        if connectionType == .wifi, isOnHomeNetwork, let reachable = await probeInternalBrokerIfConfigured() {
            guard gen == generation else { return }
            if reachable {
                // Previously-confirmed home + broker still reachable → hold.
                print("🏠 [NetworkMonitor] SSID unreadable — internal broker still reachable, keeping home determination")
                AppLogger.shared.log("SSID unreadable — internal broker probe OK, holding home/internal", category: .network)
            } else {
                currentSSID = nil
                isOnHomeNetwork = false
                print("🌍 [NetworkMonitor] SSID unreadable — internal broker unreachable, switching to external")
                AppLogger.shared.log("SSID unreadable — internal broker probe failed → external", category: .network)
            }
            return
        }

        // Subnet check — the one signal that works while backgrounded, needs no
        // permission, and costs no I/O. If the internal broker's address is a
        // literal IP that cannot exist on the subnet we're attached to, we have
        // definitively left home, regardless of what SSID we last saw.
        //
        // This is the case the TCP probe above CANNOT cover: it returns nil
        // whenever MQTT is off or no internal host is set, so control falls
        // straight through to the hold branch below and a stale "home" sticks
        // all night. Downgrade-only by design — see LocalSubnet for why a
        // subnet MATCH is not sufficient to upgrade in the other direction.
        if connectionType == .wifi, isOnHomeNetwork,
           LocalSubnet.isProvablyOffSubnet(host: DeviceSettings.shared.mqttInternalHost) {
            currentSSID = nil
            isOnHomeNetwork = false
            let subnet = LocalSubnet.describeWifiSubnet() ?? "unknown"
            print("🌍 [NetworkMonitor] Internal broker is off the current subnet (\(subnet)) — switching to external")
            AppLogger.shared.log(
                "Internal broker IP outside current Wi-Fi subnet → external",
                category: .network
            )
            return
        }

        // Probe unavailable (MQTT off / no internal host configured): if we're
        // still on Wi-Fi with a previously confirmed SSID and the app is
        // backgrounded, HOLD the previous determination rather than degrading
        // to external. Foreground (refreshOnForeground) re-evaluates for real.
        if connectionType == .wifi,
           let held = currentSSID,
           UIApplication.shared.applicationState != .active {
            print("⚠️ [NetworkMonitor] SSID unreadable while backgrounded — holding previous determination: \(held) (home=\(isOnHomeNetwork))")
            AppLogger.shared.log("SSID unreadable (backgrounded) — holding \(isOnHomeNetwork ? "home/internal" : "external") determination", category: .network)
            return
        }

        currentSSID = nil
        isOnHomeNetwork = false
        print("⚠️ [NetworkMonitor] No SSID resolved — not on Wi-Fi, location denied, Wi-Fi off, or VPN interference.")
    }

    /// TCP reachability probe of the internal MQTT broker (3s timeout).
    /// Returns nil when the probe isn't applicable (MQTT disabled or no
    /// internal host configured); true/false = broker reachable/unreachable.
    /// A plain TCP connect is enough — we only need to know the host answers
    /// on the LAN, not to complete an MQTT handshake.
    private func probeInternalBrokerIfConfigured() async -> Bool? {
        let settings = DeviceSettings.shared
        let host = settings.mqttInternalHost
        guard settings.mqttEnabled, !host.isEmpty,
              let port = NWEndpoint.Port(rawValue: UInt16(clamping: settings.mqttInternalPort)) else {
            return nil
        }

        let probeQueue = queue
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            // All resume attempts run on the same serial queue, so a plain
            // flag is race-free.
            var resumed = false
            func finish(_ result: Bool) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
                connection.cancel()
            }
            connection.stateUpdateHandler = { state in
                probeQueue.async {
                    switch state {
                    case .ready: finish(true)
                    case .failed, .cancelled: finish(false)
                    default: break
                    }
                }
            }
            connection.start(queue: probeQueue)
            probeQueue.asyncAfter(deadline: .now() + 3) {
                finish(false)
            }
        }
    }

    /// Foreground re-evaluation: the SSID is reliably readable again, so
    /// re-resolve and notify MQTT only if the determination actually changed.
    private func refreshOnForeground() {
        guard connectionType == .wifi else { return }
        Task { @MainActor in
            let ssidBefore = currentSSID
            let homeBefore = isOnHomeNetwork
            await resolveSSID(generation: generation)
            if currentSSID != ssidBefore || isOnHomeNetwork != homeBefore {
                print("🌐 [NetworkMonitor] Foreground SSID re-check changed state: \(connectionDescription) (home=\(isOnHomeNetwork))")
                AppLogger.shared.log("Foreground SSID re-check: \(connectionDescription) → \(isOnHomeNetwork ? "home/internal" : "external")", category: .network)
                NotificationCenter.default.post(name: NSNotification.Name("NetworkChanged"), object: nil)
            }
        }
    }
    
    /// Check if current SSID matches configured home SSIDs
    private func checkIfHomeNetwork(_ ssid: String) {
        let homeSSIDs = DeviceSettings.shared.homeSSIDs
        isOnHomeNetwork = homeSSIDs.contains(ssid)
        
        if isOnHomeNetwork {
            print("🏠 On home network: \(ssid)")
            AppLogger.shared.log("On home network (SSID matched)", category: .network)
        } else {
            print("🌍 On external network: \(ssid)")
            AppLogger.shared.log("On external network (SSID not in home list)", category: .network)
        }
    }
    
    /// Force refresh SSID (call when settings change). Re-resolves under the current
    /// generation so a concurrent network change still wins.
    func refreshSSID() {
        Task { @MainActor in
            await resolveSSID(generation: generation)
        }
    }
    
    /// Get broker configuration based on current network
    func getBrokerConfig(settings: DeviceSettings) -> (host: String, port: Int, useTLS: Bool) {
        // Always use external connection (user preference)
        if settings.forceExternalConnection {
            print("🌍 [NetworkMonitor] Forcing external connection (user preference)")
            return (
                host: settings.mqttExternalHost,
                port: settings.mqttExternalPort,
                useTLS: true
            )
        }
        
        // Debug mode: Force home network (bypass WiFi detection)
        if settings.debugForceHomeNetwork {
            print("🔧 [DEBUG] Forcing home network (bypassing WiFi detection)")
            return (
                host: settings.mqttInternalHost,
                port: settings.mqttInternalPort,
                useTLS: settings.mqttUseTLS
            )
        }

        // Home/internal is only a real option if an internal broker actually
        // exists. Without this, an unconfigured internal host returned an empty
        // host, MQTTManager.connect bailed out with .notConfigured, and it
        // never tried the external broker — so MQTT simply never connected and
        // never retried, which is the "local didn't respond and it wouldn't
        // fall back" symptom.
        let hasInternalBroker = !settings.mqttInternalHost
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if (isOnHomeNetwork || connectionType == .wiredEthernet) && hasInternalBroker {
            // Use internal broker (home network)
            return (
                host: settings.mqttInternalHost,
                port: settings.mqttInternalPort,
                useTLS: settings.mqttUseTLS
            )
        } else {
            // Use external broker (cellular or external WiFi)
            // TLS is always enforced for external/remote connections
            return (
                host: settings.mqttExternalHost,
                port: settings.mqttExternalPort,
                useTLS: true
            )
        }
    }
    
    var connectionDescription: String {
        if !isConnected {
            return "No connection"
        }
        
        switch connectionType {
        case .wifi:
            if let ssid = currentSSID {
                return "WiFi: \(ssid)"
            }
            return "WiFi (unknown network)"
        case .cellular:
            return "Cellular"
        case .wiredEthernet:
            return "Ethernet"
        default:
            return "Connected"
        }
    }
}
