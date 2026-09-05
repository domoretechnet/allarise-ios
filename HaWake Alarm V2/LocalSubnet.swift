//
//  LocalSubnet.swift
//  HaWake Alarm V2
//
//  Answers "could this broker address possibly be on the network I'm attached
//  to right now?" using only getifaddrs — no entitlement, no permission, and
//  crucially NO FOREGROUND REQUIREMENT.
//
//  Why this exists: home-network detection is SSID-based, and iOS denies SSID
//  reads outright while the app is backgrounded (see NetworkMonitor.resolveSSID).
//  Overnight that means the app holds whatever it last decided — so joining an
//  unknown Wi-Fi after last being home leaves it dialing an internal broker
//  that isn't on this subnet, with a 15s timeout per attempt and backoff out to
//  5 minutes, forever. The TCP probe that would catch this returns nil whenever
//  no internal host is configured, so it never runs in exactly that case.
//
//  SECURITY — this is a DOWNGRADE-ONLY signal, deliberately.
//  A subnet MISMATCH is proof the address is unreachable locally: safe to act
//  on. A subnet MATCH proves almost nothing — 192.168.1.0/24 is the most common
//  home subnet in the world, so any café or hotel can match it, and a "match"
//  must never be allowed to promote external → internal and send credentials
//  onto an unverified network over plain TCP. That mirrors the confirm-or-
//  downgrade-only rule already documented on NetworkMonitor's TCP probe.
//

import Foundation

enum LocalSubnet {
    /// An interface's IPv4 address and netmask, as 32-bit host-order values.
    struct IPv4Interface {
        let address: UInt32
        let netmask: UInt32
        var network: UInt32 { address & netmask }
    }

    /// IPv4 config for the active Wi-Fi interface (`en0`), or nil if not on
    /// Wi-Fi / no IPv4 address assigned.
    static func wifiInterface() -> IPv4Interface? {
        interface(named: "en0")
    }

    static func interface(named wanted: String) -> IPv4Interface? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }

            guard let rawName = current.pointee.ifa_name,
                  String(cString: rawName) == wanted,
                  let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = current.pointee.ifa_netmask else { continue }

            // Skip interfaces that are down or have no assigned address.
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }

            let address = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            guard address != 0, netmask != 0 else { continue }
            return IPv4Interface(address: address, netmask: netmask)
        }
        return nil
    }

    /// Parse a dotted-quad IPv4 literal. Returns nil for hostnames — callers
    /// must treat that as NO SIGNAL, never as a mismatch. Users routinely enter
    /// `homeassistant.local` or `mosquitto.lan`, and resolving those requires
    /// mDNS that fails (or worse, resolves to a different device) off-network.
    static func parseIPv4(_ string: String) -> UInt32? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard part.count <= 3, !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let octet = UInt32(part), octet <= 255 else { return nil }
            result = (result << 8) | octet
        }
        return result
    }

    /// Whether `host` is PROVABLY unreachable on the current Wi-Fi subnet.
    ///
    /// Returns false — meaning "no conclusion", not "reachable" — whenever the
    /// answer is uncertain: host is a name rather than an IP, we're not on
    /// Wi-Fi, or the interface has no IPv4 address. Only a confident mismatch
    /// returns true.
    static func isProvablyOffSubnet(host: String) -> Bool {
        guard let target = parseIPv4(host),
              let local = wifiInterface() else { return false }
        return (target & local.netmask) != local.network
    }

    /// Human-readable current Wi-Fi subnet, for logging. e.g. "192.168.10.66/24".
    static func describeWifiSubnet() -> String? {
        guard let local = wifiInterface() else { return nil }
        let a = local.address
        let dotted = "\((a >> 24) & 255).\((a >> 16) & 255).\((a >> 8) & 255).\(a & 255)"
        let prefix = local.netmask.nonzeroBitCount
        return "\(dotted)/\(prefix)"
    }
}
