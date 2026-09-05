//
//  WeatherSpeechFormatter.swift
//  HaWake Alarm V2
//
//  Builds the spoken weather summary for the Siri intent. Formatting rules
//  mirror GoodMorningWeatherView's formatters (locale-aware units,
//  whole-number temperatures).
//

import Foundation
import WeatherKit

enum WeatherSpeechFormatter {

    static func summary(
        current: CurrentWeather,
        daily: Forecast<DayWeather>,
        locationName: String?
    ) -> String {
        var sentences: [String] = []

        let place = locationName.map { " in \($0)" } ?? ""
        let condition = spokenCondition(current.condition)
        sentences.append("It's \(formatTemp(current.temperature)) and \(condition)\(place).")

        if let today = daily.first {
            let high = formatTemp(today.highTemperature)
            let low = formatTemp(today.lowTemperature)
            var line = "Today: high of \(high), low of \(low)"
            let precip = Int((today.precipitationChance * 100).rounded())
            if precip >= 10 {
                line += ", with a \(precip) percent chance of precipitation"
            }
            sentences.append(line + ".")
        }

        return sentences.joined(separator: " ")
    }

    /// "72°" in the user's locale unit — Siri reads the degree sign naturally.
    /// Same approach as GoodMorningWeatherView.formatTemp.
    private static func formatTemp(_ measurement: Measurement<UnitTemperature>) -> String {
        let formatted = measurement.formatted(.measurement(
            width: .narrow,
            usage: .weather,
            numberFormatStyle: .number.precision(.fractionLength(0))
        ))
        return formatted
            .replacingOccurrences(of: "F", with: "")
            .replacingOccurrences(of: "C", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// WeatherCondition descriptions are already human-readable ("Partly Cloudy");
    /// lowercase them for mid-sentence speech.
    private static func spokenCondition(_ condition: WeatherCondition) -> String {
        condition.description.lowercased()
    }
}
