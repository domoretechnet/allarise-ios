//
//  VerseOfDayPreviewTests.swift
//  HaWake Alarm V2Tests
//
//  The "Try It Out" verse preview shows YESTERDAY's verse, so tapping Preview
//  Verse in the After-Alarm editor doesn't spoil the one the user will wake up
//  to. The real post-alarm card is untouched and still shows today's.
//
//  Two things are worth pinning down and both are testable without disk or
//  network:
//
//    • the selection rule — prefer yesterday, fall back to today, never nothing;
//    • the "yesterday" arithmetic — calendar days, not 86,400 seconds, so a DST
//      spring-forward morning doesn't resolve back into today.
//
//  Reference: Documents/26-VERSE-OF-THE-DAY.md
//

import Foundation
import Testing
@testable import HaWake_Alarm_V2

// MARK: - Helpers

private func makeVerse(_ key: String, reference: String = "Psalm 46:1") -> VerseOfDay {
    VerseOfDay(
        date: key,
        reference: reference,
        text: "God is our refuge and strength, a very present help in trouble.",
        translation: "WEB",
        imageURL: nil,
        isFallback: false
    )
}

/// A calendar pinned to a fixed zone so day arithmetic is reproducible on any
/// machine. New York is deliberate: it observes DST.
private func fixedCalendar(_ identifier: String = "America/New_York") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: identifier)!
    return calendar
}

private func date(_ year: Int, _ month: Int, _ day: Int,
                  hour: Int = 0, minute: Int = 0,
                  in calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day,
                                       hour: hour, minute: minute))!
}

// MARK: - Selection rule

struct VersePreviewSelectionTests {

    @Test("Yesterday's verse wins when we have it, and is flagged as yesterday's")
    func prefersYesterday() {
        let today = makeVerse("2026-07-27", reference: "Isaiah 40:31")
        let yesterday = makeVerse("2026-07-26", reference: "Joshua 1:9")

        let preview = VerseOfDayService.previewSelection(today: today, yesterday: yesterday)

        #expect(preview.verse == yesterday)
        #expect(preview.isYesterday)
    }

    @Test("With no cached yesterday the preview falls back to today, uncaptioned")
    func fallsBackToToday() {
        let today = makeVerse("2026-07-27", reference: "Isaiah 40:31")

        let preview = VerseOfDayService.previewSelection(today: today, yesterday: nil)

        // Falling back to today is the whole point of the fallback: the preview
        // must never come up empty, even on a cold cache.
        #expect(preview.verse == today)
        #expect(!preview.isYesterday)
    }

    @Test("The bundled offline fallback verse is still previewable")
    func fallbackVerseIsPreviewable() {
        let bundled = VerseOfDay(
            date: "2026-07-27",
            reference: "Philippians 4:13",
            text: "I can do all things through Christ, who strengthens me.",
            translation: "WEB",
            imageURL: nil,
            isFallback: true
        )

        let preview = VerseOfDayService.previewSelection(today: bundled, yesterday: nil)

        #expect(preview.verse == bundled)
        #expect(!preview.isYesterday)
    }
}

// MARK: - "Yesterday" arithmetic

struct VersePreviousDayTests {

    @Test("Yesterday is the start of the previous calendar day")
    func plainDay() throws {
        let calendar = fixedCalendar()
        let now = date(2026, 7, 27, hour: 14, minute: 32, in: calendar)

        let yesterday = try #require(VerseOfDayService.previousDay(before: now, calendar: calendar))

        let components = calendar.dateComponents([.year, .month, .day, .hour], from: yesterday)
        #expect(components.year == 2026)
        #expect(components.month == 7)
        #expect(components.day == 26)
        #expect(components.hour == 0)
    }

    @Test("Yesterday crosses a month boundary")
    func monthBoundary() throws {
        let calendar = fixedCalendar()
        let now = date(2026, 8, 1, hour: 6, in: calendar)

        let yesterday = try #require(VerseOfDayService.previousDay(before: now, calendar: calendar))

        let components = calendar.dateComponents([.year, .month, .day], from: yesterday)
        #expect(components.year == 2026)
        #expect(components.month == 7)
        #expect(components.day == 31)
    }

    @Test("Yesterday crosses a year boundary")
    func yearBoundary() throws {
        let calendar = fixedCalendar()
        let now = date(2026, 1, 1, hour: 0, minute: 5, in: calendar)

        let yesterday = try #require(VerseOfDayService.previousDay(before: now, calendar: calendar))

        let components = calendar.dateComponents([.year, .month, .day], from: yesterday)
        #expect(components.year == 2025)
        #expect(components.month == 12)
        #expect(components.day == 31)
    }

    @Test("A DST spring-forward morning still resolves to the previous day")
    func springForward() throws {
        // 2026-03-08 is the US spring-forward date: that local day is 23 hours
        // long, so subtracting a flat 86,400s from 06:00 would land at 07:00 the
        // SAME morning — and the preview would show today's verse after all.
        let calendar = fixedCalendar()
        let now = date(2026, 3, 8, hour: 6, in: calendar)

        let yesterday = try #require(VerseOfDayService.previousDay(before: now, calendar: calendar))

        let components = calendar.dateComponents([.year, .month, .day], from: yesterday)
        #expect(components.month == 3)
        #expect(components.day == 7)
        #expect(!calendar.isDate(yesterday, inSameDayAs: now))
    }

    @Test("A DST fall-back morning still resolves to the previous day")
    func fallBack() throws {
        // 2026-11-01, the 25-hour day — the mirror image of the case above.
        let calendar = fixedCalendar()
        let now = date(2026, 11, 1, hour: 6, in: calendar)

        let yesterday = try #require(VerseOfDayService.previousDay(before: now, calendar: calendar))

        let components = calendar.dateComponents([.year, .month, .day], from: yesterday)
        #expect(components.month == 10)
        #expect(components.day == 31)
        #expect(!calendar.isDate(yesterday, inSameDayAs: now))
    }

    @Test("Yesterday's day-key differs from today's")
    func keyDiffersFromToday() throws {
        let now = Date()
        let yesterday = try #require(VerseOfDayService.previousDay(before: now))

        #expect(VerseOfDayService.dateKey(for: yesterday) != VerseOfDayService.dateKey(for: now))
    }
}

// MARK: - Service integration (disk-only, no network)

@MainActor
struct VersePreviewServiceTests {

    @Test("previewVerse always returns something, dated today or yesterday")
    func previewNeverEmpty() throws {
        let now = Date()
        let preview = VerseOfDayService.shared.previewVerse(relativeTo: now)

        let todayKey = VerseOfDayService.dateKey(for: now)
        let yesterdayKey = try #require(VerseOfDayService.previousDay(before: now).map {
            VerseOfDayService.dateKey(for: $0)
        })

        #expect(!preview.verse.text.isEmpty)
        #expect(!preview.verse.reference.isEmpty)
        // Whichever branch the cache put us on, the flag must match the verse —
        // a today verse captioned "Yesterday's verse" would be a lie.
        #expect(preview.verse.date == (preview.isYesterday ? yesterdayKey : todayKey))
    }

    @Test("The real post-alarm card still resolves today's verse")
    func todayIsUnchanged() {
        let now = Date()
        let verse = VerseOfDayService.shared.verseForToday(now)

        #expect(verse.date == VerseOfDayService.dateKey(for: now))
    }
}
