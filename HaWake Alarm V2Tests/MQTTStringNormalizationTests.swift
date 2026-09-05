//
//  MQTTStringNormalizationTests.swift
//  HaWake Alarm V2Tests
//
//  Pins down the normalisation applied to strings crossing the Home Assistant
//  boundary — `MQTTStrings`, plus the two tolerant lookups built on it
//  (`MQTTCommandHandler.command(named:in:)` and `.favourite(matching:in:)`).
//
//  The point of most of these tests is what must NOT change. A command's topic
//  slug is baked into the entity_id Home Assistant generated for it, and a
//  station name that resolved yesterday has to resolve today, so the majority
//  of the assertions below are "this input still produces exactly what it
//  always produced".
//
//  Reference: Documents/15-INBOUND-COMMANDS-REFERENCE.md
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

// MARK: - Match keys

struct MQTTStringMatchKeyTests {

    @Test("Trailing and leading whitespace is not part of the identity")
    func trimsEnds() {
        #expect(MQTTStrings.matchKey("  Lights  ") == "lights")
    }

    @Test("A run of whitespace folds to one space")
    func collapsesRuns() {
        #expect(MQTTStrings.matchKey("Living   Room  Lamp") == "living room lamp")
    }

    @Test("Non-breaking and zero-width characters do not create a different name")
    func foldsInvisibleCharacters() {
        // U+00A0 no-break space, U+200B zero-width space — both routinely
        // arrive in a name pasted out of a web page or a radio directory.
        #expect(MQTTStrings.matchKey("Living\u{00A0}Room") == "living room")
        #expect(MQTTStrings.matchKey("WD\u{200B}ET") == "wdet")
    }

    @Test("Control characters are removed, not turned into spaces")
    func stripsControls() {
        #expect(MQTTStrings.matchKey("Li\u{0000}ghts") == "lights")
    }

    @Test("Emoji and punctuation survive — they are part of the name")
    func keepsEmoji() {
        #expect(MQTTStrings.matchKey("Coffee ☕") == "coffee ☕")
        #expect(MQTTStrings.matchKey("Lights (Hall)") == "lights (hall)")
    }
}

// MARK: - Published names

struct MQTTStringPublishedNameTests {

    @Test("A name Home Assistant could already hold is published unchanged")
    func leavesCleanNamesAlone() {
        #expect(MQTTStrings.publishedName("SomaFM Groove Salad") == "SomaFM Groove Salad")
    }

    @Test("Newlines never reach an entity state")
    func flattensNewlines() {
        #expect(MQTTStrings.publishedName("KEXP\nSeattle") == "KEXP Seattle")
    }

    @Test("Truncated at Home Assistant's 255-character state limit")
    func capsAtStateLimit() {
        let long = String(repeating: "A", count: 400)
        #expect(MQTTStrings.publishedName(long).count == MQTTStrings.maxStateLength)
    }

    @Test("Blanks and de-duplication are handled together for a dropdown")
    func uniqueNonEmpty() {
        let cleaned = ["WDET", "", "wdet ", "KEXP"].map { MQTTStrings.publishedName($0) }
        #expect(MQTTStrings.uniqueNonEmpty(cleaned) == ["WDET", "KEXP"])
    }
}

// MARK: - Command topic slugs

struct MQTTCommandTopicSlugTests {

    // PUBLISHED CONTRACT. Each of these produced exactly this slug before the
    // helper existed, and the slug is half of the entity_id Home Assistant
    // generated for that command's sensor. Changing one orphans the entity and
    // every automation pointing at it.
    @Test("Existing slugs are byte-identical to the historical transform",
          arguments: [
            ("Lights", "lights"),
            ("Living Room", "living_room"),
            ("LR Shutdown", "lr_shutdown"),
            ("Lr-Lights", "lrlights"),          // hyphens have always been stripped
            ("Good Morning!", "good_morning"),
            ("Zone 2 / Kitchen", "zone_2__kitchen"),
          ])
    func historicalSlugsUnchanged(input: String, expected: String) {
        #expect(MQTTStrings.commandTopicSlug(input) == expected)
    }

    @Test("A name with no sluggable characters gets a stable fallback")
    func fallbackForUnsluggableNames() {
        // These used to slug to "" and publish to `.../command//status`, which
        // the integration reads as an empty command name and drops — the
        // command simply had no sensor and nothing said why.
        for name in ["☕", "日本語", "!!!", "___"] {
            let slug = MQTTStrings.commandTopicSlug(name)
            #expect(!slug.isEmpty)
            #expect(slug.hasPrefix("cmd_"))
        }
    }

    @Test("The fallback is stable across calls — a topic cannot move")
    func fallbackIsStable() {
        let first = MQTTStrings.commandTopicSlug("☕")
        let second = MQTTStrings.commandTopicSlug("☕")
        #expect(first == second)
    }

    @Test("Different unsluggable names get different fallbacks")
    func fallbacksDoNotCollide() {
        #expect(MQTTStrings.commandTopicSlug("☕") != MQTTStrings.commandTopicSlug("🍵"))
    }

    @Test("MQTT wildcards and separators cannot reach the topic")
    func noTopicInjection() {
        // A command name is the only inbound string that becomes a topic
        // segment. `+`, `#` and `/` are all outside [a-z0-9_] and were already
        // stripped; this test exists so that stays true.
        let slug = MQTTStrings.commandTopicSlug("a/+/#b")
        #expect(!slug.contains("/"))
        #expect(!slug.contains("+"))
        #expect(!slug.contains("#"))
    }
}

// MARK: - File-name safety

struct MQTTStringFileComponentTests {

    @Test("Real sleep sound names are accepted",
          arguments: ["Brown_Noise", "white_noise", "custom_8B0D2F1A", "My Rain Mix"])
    func acceptsRealNames(name: String) {
        #expect(MQTTStrings.isSafeFileComponent(name))
    }

    @Test("Anything that would build a path elsewhere is refused",
          arguments: ["../secrets", "..", ".", "", "a/b", "a\\b", "sounds:alt", "nul\u{0000}l"])
    func refusesPathTricks(name: String) {
        #expect(!MQTTStrings.isSafeFileComponent(name))
    }
}

// MARK: - Tolerant command lookup

@MainActor
struct MQTTCommandLookupTests {

    private var commands: [MQTTCommand] {
        [
            MQTTCommand(name: "Lights"),
            MQTTCommand(name: "lights"),        // deliberately case-different
            MQTTCommand(name: "Living Room"),
        ]
    }

    @Test("An exact name still wins, even when another differs only by case")
    func exactMatchWins() {
        let list = commands
        #expect(MQTTCommandHandler.command(named: "lights", in: list)?.name == "lights")
        #expect(MQTTCommandHandler.command(named: "Lights", in: list)?.name == "Lights")
    }

    @Test("A stray space no longer costs the lookup")
    func toleratesWhitespace() {
        #expect(MQTTCommandHandler.command(named: " Living Room ", in: commands)?.name == "Living Room")
        #expect(MQTTCommandHandler.command(named: "Living  Room", in: commands)?.name == "Living Room")
    }

    @Test("A name that matches nothing still matches nothing")
    func unknownNameIsNil() {
        #expect(MQTTCommandHandler.command(named: "Garage", in: commands) == nil)
    }

    @Test("A blank name never resolves to an arbitrary command")
    func blankNameIsNil() {
        #expect(MQTTCommandHandler.command(named: "", in: commands) == nil)
        #expect(MQTTCommandHandler.command(named: "   ", in: commands) == nil)
    }
}

// MARK: - Tolerant radio favourite lookup

@MainActor
struct MQTTRadioFavouriteLookupTests {

    private func station(_ id: String, _ name: String) -> RadioStation {
        RadioStation(
            id: id,
            name: name,
            streamURL: "https://example.invalid/\(id)",
            faviconURL: nil,
            country: "",
            tags: "",
            codec: "",
            bitrate: 0
        )
    }

    private var favourites: [RadioStation] {
        [
            station("uuid-1", "WDET 101.9 FM "),   // trailing space, as the directory gave it
            station("uuid-2", "KEXP\u{00A0}90.3"), // no-break space in the middle
        ]
    }

    @Test("Case-insensitive exact name — the original behaviour, unchanged")
    func exactNameStillResolves() {
        #expect(MQTTCommandHandler.favourite(matching: "wdet 101.9 fm ", in: favourites)?.id == "uuid-1")
    }

    @Test("A station UUID still resolves")
    func uuidStillResolves() {
        #expect(MQTTCommandHandler.favourite(matching: "uuid-2", in: favourites)?.id == "uuid-2")
    }

    @Test("The CLEANED name Home Assistant sends back now resolves too")
    func cleanedNameResolves() {
        // This is the round trip that used to silently fail: the app publishes
        // the cleaned name so the dropdown is usable, the user picks it, and
        // the value coming back no longer matched the stored favourite.
        let published = MQTTStrings.publishedName("WDET 101.9 FM ")
        #expect(published == "WDET 101.9 FM")
        #expect(MQTTCommandHandler.favourite(matching: published, in: favourites)?.id == "uuid-1")

        let publishedKEXP = MQTTStrings.publishedName("KEXP\u{00A0}90.3")
        #expect(publishedKEXP == "KEXP 90.3")
        #expect(MQTTCommandHandler.favourite(matching: publishedKEXP, in: favourites)?.id == "uuid-2")
    }

    @Test("A typo still fails, rather than resolving to something arbitrary")
    func unknownStationIsNil() {
        #expect(MQTTCommandHandler.favourite(matching: "WXYZ", in: favourites) == nil)
    }

    @Test("An empty needle never resolves")
    func emptyNeedleIsNil() {
        #expect(MQTTCommandHandler.favourite(matching: "", in: favourites) == nil)
    }
}
