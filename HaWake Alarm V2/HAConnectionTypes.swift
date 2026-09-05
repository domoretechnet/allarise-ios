//
//  HAConnectionTypes.swift
//  HaWake Alarm V2
//
//  Shared types for Home Assistant communication via MQTT
//

import Foundation

enum AlarmState: String {
    case idle = "idle"
    case ringing = "ringing"
    case snoozed = "snoozed"
    case dismissed = "dismissed"
}

enum HAConnectionState {
    case disconnected
    case connecting
    case connected
    case notConfigured
    case error(String)
    
    var description: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .notConfigured: return "No Broker Configured"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

/// Backward compatibility alias
typealias MQTTConnectionState = HAConnectionState
