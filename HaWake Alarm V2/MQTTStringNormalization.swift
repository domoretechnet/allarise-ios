//
//  MQTTStringNormalization.swift
//  HaWake Alarm V2
//
//  Normalisation for strings that cross the Home Assistant boundary.
//
//  Three distinct jobs live here, and it matters which one a caller wants:
//
//  1. `matchKey` — a **tolerant lookup key**. Used only as a FALLBACK after an
//     exact match has already failed, so nothing that resolved before can start
//     resolving differently. It exists because the same name can reach us in
//     more than one shape: typed into an automation with a trailing space,
//     round-tripped through a Home Assistant dropdown that trimmed it, or
//     copied out of a radio directory that put a non-breaking space in the
//     middle of it. Matching on the normalised form makes all of those find the
//     one thing the user meant.
//
//  2. `publishedName` — cleanup for a name we PUBLISH as an entity state.
//     Home Assistant refuses any state longer than 255 characters (it logs an
//     exception and parks the entity on "unknown"), and a control character in
//     a state renders as mojibake in every dashboard that shows it. Radio
//     Browser station names routinely carry both.
//
//  3. `commandTopicSlug` — the MQTT topic segment a command's status is
//     published under. **The output for any name that works today must not
//     change**, because the segment is baked into the entity_id Home Assistant
//     generated for that command's sensor; changing it orphans the old entity
//     and every automation pointing at it. The only behaviour added is a
//     fallback for names that currently slug to nothing at all.
//
//  Pure, no side effects, no persistence — exercised directly by
//  `MQTTStringNormalizationTests`.
//

import Foundation

enum MQTTStrings {

    /// Longest string Home Assistant will accept as an entity state.
    /// Mirrors `MAX_LENGTH_STATE_STATE` in `homeassistant/const.py`.
    static let maxStateLength = 255

    /// Characters that must never survive into a name, a topic, or an entity
    /// state: the full C0 block, DEL, and the C1 block. None of these can
    /// appear in text a human meant to type; all of them break something
    /// downstream. `collapsed` folds tab/newline into spaces by splitting on
    /// whitespace *before* this set is applied.
    private static let disallowedControls: CharacterSet = {
        var set = CharacterSet(charactersIn: UnicodeScalar(0x00)...UnicodeScalar(0x1F))
        set.insert(charactersIn: UnicodeScalar(0x7F)...UnicodeScalar(0x9F))
        // Zero-width and bidi-control characters, which are invisible in the UI
        // but make two "identical" names compare unequal.
        set.insert(charactersIn: "\u{200B}\u{200C}\u{200D}\u{200E}\u{200F}\u{FEFF}")
        return set
    }()

    /// Strip control characters, fold every run of whitespace (including
    /// non-breaking and other Unicode spaces) down to one plain space, and trim.
    /// Leaves letters, digits, punctuation and emoji exactly as they are.
    private static func collapsed(_ raw: String) -> String {
        let pieces = raw.split(whereSeparator: { $0.isWhitespace })
            .map { piece in
                let scalars = piece.unicodeScalars.filter { !disallowedControls.contains($0) }
                return String(String.UnicodeScalarView(scalars))
            }
            .filter { !$0.isEmpty }
        return pieces.joined(separator: " ")
    }

    /// A tolerant comparison key for name lookups.
    ///
    /// Case-insensitive, whitespace-insensitive, control-character-insensitive.
    /// Use it as a *fallback* after an exact `==` comparison, never instead of
    /// one — two commands deliberately named "Lights" and "lights" must keep
    /// resolving to themselves when an automation asks for them by exact name.
    static func matchKey(_ raw: String) -> String {
        collapsed(raw).lowercased()
    }

    /// Clean a name for publication as a Home Assistant entity state.
    ///
    /// Truncates rather than dropping: a station whose name is 400 characters
    /// long should still show up in the dropdown, shortened, instead of taking
    /// the whole entity down with it.
    static func publishedName(_ raw: String, maxLength: Int = maxStateLength) -> String {
        let cleaned = collapsed(raw)
        guard cleaned.count > maxLength else { return cleaned }
        return String(cleaned.prefix(maxLength))
    }

    /// Cleanup for a name we are about to STORE, as opposed to publish.
    ///
    /// Deliberately gentler than `publishedName`: control characters go and the
    /// ends are trimmed, but internal spacing is left exactly as the user wrote
    /// it. Collapsing "Lights  On" to "Lights On" would change the command's
    /// topic slug from `lights__on` to `lights_on`, orphaning the Home
    /// Assistant sensor and every automation pointing at it — a rename is not
    /// worth that. Trimming the ends is safe: a leading space is never
    /// deliberate, and the integration now trims before sending anyway.
    static func trimmedForStorage(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.filter { !disallowedControls.contains($0) }
        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when `name` is safe to use as a single file-system path component.
    ///
    /// `sleep_sound_start` takes a sound name straight off the wire and the
    /// resolver appends ".m4a" to it, so a name containing a separator or a
    /// parent reference builds a path somewhere other than the sounds folder.
    /// Nothing outside the sandbox is reachable, but "play whatever file this
    /// string points at" is not a contract this app should offer to the network.
    static func isSafeFileComponent(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        guard name != ".", name != ".." else { return false }
        guard !name.contains("/"), !name.contains("\\"), !name.contains(":") else { return false }
        guard !name.contains("..") else { return false }
        // A control character or a NUL in a path is never legitimate.
        return name.unicodeScalars.allSatisfy { !disallowedControls.contains($0) }
    }

    /// The MQTT topic segment a command's `.../command/{slug}/status` topic uses.
    ///
    /// **The transform for any name that already produces a non-empty slug is
    /// unchanged and must stay that way** — lowercase, spaces to underscores,
    /// everything outside `[a-z0-9_]` removed. Hyphens are stripped, which is
    /// not what you would design today, but "Lr-Lights" has published to
    /// `lrlights` since the feature shipped and Home Assistant built an
    /// entity_id from it.
    ///
    /// What is new: a name made entirely of characters the filter removes
    /// ("☕", "日本語", "!!!") used to slug to the empty string and publish to
    /// `.../command//status`. The integration reads the segment out of the
    /// topic, sees an empty name and drops the message, so the command simply
    /// had no sensor in Home Assistant and nobody could see why. Those names now
    /// get a stable `cmd_<hash>` slug instead — ugly, but present and constant
    /// across launches.
    static func commandTopicSlug(_ name: String) -> String {
        let slug = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "[^a-z0-9_]", with: "", options: .regularExpression)

        // "____" is as unusable as "" — the integration would create a sensor
        // named after nothing, and every such command would collide.
        if slug.isEmpty || slug.allSatisfy({ $0 == "_" }) {
            return "cmd_\(AlertIdentity.stableHash(matchKey(name)))"
        }
        return slug
    }

    /// De-duplicate a list of published names, preserving order and dropping
    /// blanks.
    ///
    /// Home Assistant's `SelectEntity` does not de-duplicate its options: two
    /// favourites that clean to the same name give the user two identical rows,
    /// only one of which the app can ever resolve. An empty option is worse —
    /// it renders as a blank row and selecting it is a silent no-op.
    static func uniqueNonEmpty(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names where !name.isEmpty {
            let key = matchKey(name)
            if seen.insert(key).inserted {
                result.append(name)
            }
        }
        return result
    }
}
