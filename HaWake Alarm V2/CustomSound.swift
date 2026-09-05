//
//  CustomSound.swift
//  HaWake Alarm V2
//
//  Data model for user-imported custom sounds (alarm tones and sleep sounds).
//

import Foundation

struct CustomSound: Codable, Identifiable, Hashable {
    let id: String              // "custom_<UUID>" — avoids collision with bundle sounds
    var name: String            // User-editable display name
    let category: Category
    let fileExtension: String   // "wav" for alarm tones, original extension for sleep sounds
    let importDate: Date
    let fileSizeBytes: Int64
    var durationSeconds: Double
    var sortOrder: Int

    enum Category: String, Codable {
        case alarmTone
        case sleepSound
    }

    /// MQTT-safe name: display name with spaces replaced by underscores
    var mqttName: String {
        name.replacingOccurrences(of: " ", with: "_")
    }

    /// Full file name on disk (e.g. "custom_abc123.wav")
    var fileName: String {
        "\(id).\(fileExtension)"
    }

    /// Validates a name for MQTT compatibility.
    /// Allowed: letters, digits, spaces, underscores, hyphens. 1–64 characters.
    static func isValidMQTTName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard (1...64).contains(trimmed.count) else { return false }
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " _-"))
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Sanitizes a raw filename into a valid display name.
    static func sanitizedName(from rawName: String) -> String {
        // Remove extension, replace underscores with spaces
        let name = rawName
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        // Filter to allowed characters
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -"))
        let filtered = String(name.unicodeScalars.filter { allowed.contains($0) })
        let trimmed = filtered.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Custom Sound" : String(trimmed.prefix(64))
    }
}
