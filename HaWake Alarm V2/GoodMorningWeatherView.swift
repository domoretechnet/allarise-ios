//
//  GoodMorningWeatherView.swift
//  HaWake Alarm V2
//
//  Full-screen "Good Morning" weather card shown after dismissing
//  the last alarm in the queue (with an 8-hour cooldown).
//

import SwiftUI
import WeatherKit

struct GoodMorningWeatherView: View {
    let onDismiss: () -> Void
    /// Optional wallpaper image to show behind the weather card instead of the gradient.
    /// This is the shared home-theme wallpaper (same one on the home list and alarm
    /// screen) — the app has a single wallpaper setting.
    var wallpaperImage: UIImage?
    /// The appearance the wallpaper image was loaded for. The card forces its *content*
    /// to dark for legibility, so we can't derive positioning from the environment
    /// color scheme — we position with the home props for this appearance instead.
    var wallpaperIsDark: Bool = false

    @State private var weatherService = HaWakeWeatherService.shared
    @State private var autoDismissTask: Task<Void, Never>?

    // MARK: - Formatters

    /// Format a temperature as "72°" in the user's locale unit (°F or °C).
    private func formatTemp(_ measurement: Measurement<UnitTemperature>) -> String {
        let formatted = measurement.formatted(.measurement(
            width: .narrow,
            usage: .weather,
            numberFormatStyle: .number.precision(.fractionLength(0))
        ))
        // .narrow already produces "72°F" or "22°C" — strip just the letter to get "72°"
        return formatted
            .replacingOccurrences(of: "F", with: "")
            .replacingOccurrences(of: "C", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Format a wind speed measurement in the user's locale unit (mph or km/h).
    private func formatSpeed(_ measurement: Measurement<UnitSpeed>) -> String {
        measurement.formatted(.measurement(
            width: .abbreviated,
            usage: .wind,
            numberFormatStyle: .number.precision(.fractionLength(0))
        ))
    }

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f
    }

    private var dayFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            if let wallpaperImage {
                wallpaperBackground(wallpaperImage)
                    .ignoresSafeArea()
            } else {
                backgroundGradient
                    .ignoresSafeArea()
            }

            contentLayer
        }
        // The weather screen always sits on a dark wallpaper/gradient, so force a dark
        // color scheme. Otherwise .primary/.secondary text (greeting, location, condition,
        // attribution) resolves to dark colors in Light Mode and becomes illegible, and
        // the Apple Weather mark would pick the wrong (dark-on-dark) logo variant.
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .task {
            await weatherService.fetchWeather()
            startAutoDismiss()
        }
        .onDisappear {
            autoDismissTask?.cancel()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentLayer: some View {
        switch weatherService.state {
        case .idle, .loading:
            loadingView
        case .loaded(let current, let daily):
            loadedView(current: current, daily: daily)
        case .failed(let message):
            errorView(message: message)
        case .noLocation:
            errorView(message: "Enable location services for weather data")
        }
    }

    // MARK: - Loaded State

    private func loadedView(current: CurrentWeather, daily: Forecast<DayWeather>) -> some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    Spacer().frame(height: 40)

                    // Greeting
                    greetingSection

                    // Current conditions card
                    currentWeatherCard(current: current, daily: daily)

                    // 7-day forecast card
                    forecastCard(daily: daily)

                    // Apple Weather attribution
                    attributionView

                    // Bottom padding so content isn't hidden behind the floating button
                    Spacer().frame(height: 80)
                }
                .padding(.horizontal, 20)
            }

            dismissButton
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
    }

    private var greetingSection: some View {
        VStack(spacing: 4) {
            if let location = weatherService.locationName {
                Text(location + "  •  " + dateFormatter.string(from: Date()))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(dateFormatter.string(from: Date()))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func currentWeatherCard(current: CurrentWeather, daily: Forecast<DayWeather>) -> some View {
        VStack(spacing: 16) {
            // Icon + Temperature
            HStack(spacing: 16) {
                Image(systemName: current.symbolName)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 56))

                AnimatedTemperatureText(
                    value: formatTemp(current.temperature),
                    font: .system(size: 64, weight: .thin)
                )
            }

            // Condition label
            Text(current.condition.description)
                .font(.title3)
                .foregroundStyle(.secondary)

            // High / Low / Feels Like
            if let today = daily.forecast.first {
                HStack(spacing: 20) {
                    Label(formatTemp(today.highTemperature), systemImage: "arrow.up")
                    Label(formatTemp(today.lowTemperature), systemImage: "arrow.down")
                    Label("Feels " + formatTemp(current.apparentTemperature), systemImage: "thermometer.medium")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Divider().opacity(0.3)

            // Humidity + Wind
            HStack(spacing: 30) {
                Label(
                    "\(Int(current.humidity * 100))%",
                    systemImage: "humidity"
                )

                Label(
                    formatSpeed(current.wind.speed),
                    systemImage: "wind"
                )
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .glassEffect(weatherGlass, in: .rect(cornerRadius: 20))
    }

    private func forecastCard(daily: Forecast<DayWeather>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("7-Day Forecast", systemImage: "calendar")
                .font(.headline)
                .foregroundStyle(.secondary)

            ForEach(Array(daily.forecast.prefix(7).enumerated()), id: \.offset) { index, day in
                if index > 0 {
                    Divider().opacity(0.2)
                }
                forecastRow(day: day, isToday: index == 0)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .glassEffect(weatherGlass, in: .rect(cornerRadius: 20))
    }

    private func forecastRow(day: DayWeather, isToday: Bool) -> some View {
        HStack {
            Text(isToday ? "Today" : dayFormatter.string(from: day.date))
                .font(.subheadline)
                .frame(width: 50, alignment: .leading)

            Image(systemName: day.symbolName)
                .symbolRenderingMode(.multicolor)
                .font(.title3)
                .frame(width: 30)

            Spacer()

            HStack(spacing: 4) {
                Text(formatTemp(day.lowTemperature))
                    .foregroundStyle(.secondary)

                temperatureBar(low: day.lowTemperature, high: day.highTemperature)
                    .frame(width: 60, height: 4)

                Text(formatTemp(day.highTemperature))
            }
            .font(.subheadline)
        }
    }

    private func temperatureBar(low: Measurement<UnitTemperature>, high: Measurement<UnitTemperature>) -> some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [.blue.opacity(0.6), .orange.opacity(0.6)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }

    // MARK: - Attribution

    @ViewBuilder
    private var attributionView: some View {
        if let attribution = weatherService.attribution {
            VStack(spacing: 8) {
                // The whole screen is forced to a dark backdrop (.environment colorScheme
                // .dark above), so always use the dark-background mark — the light/white
                // logo — to match the now-white text. Using `self.colorScheme` here read
                // the SYSTEM scheme (not the override) and picked the black logo in Light Mode.
                let logoURL = attribution.combinedMarkDarkURL

                AsyncImage(url: logoURL) { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(height: 12)
                } placeholder: {
                    EmptyView()
                }

                // The "Weather data sources" legal LINK deliberately does not appear
                // on this card — it's a wake-up screen, not a place to send anyone to
                // a web page. The required Apple Weather mark stays here, and the full
                // attribution (mark + link) still lives on the Weather step's config
                // in the alarm editor via `AppleWeatherAttributionView`.
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Dismiss Button

    /// The theme accent this card's call-to-action wears. The card forces its
    /// *content* to dark for legibility (see the colorScheme override in `body`),
    /// but the accent override is stored per REAL appearance — so resolving for a
    /// hardcoded `.dark` misses a user who picked their accent in Light Mode, and
    /// the button falls back to the theme default instead of their colour. Resolve
    /// for the appearance this card was actually built for — the same reasoning as
    /// the wallpaper positioning below, not the attribution logo (the logo wants
    /// the white-on-dark mark regardless; the accent must follow the user's theme).
    private var accent: Color {
        DeviceSettings.shared.appAccent(for: wallpaperIsDark ? .dark : .light)
    }

    /// The app's standard full-width accent CTA — identical to the verse and
    /// notes cards' "Continue" (title3 semibold, 60pt tall, 18pt corners), so
    /// every after-alarm step ends on the same button. No glyph: the word alone
    /// reads cleaner at this size.
    private var dismissButton: some View {
        Button {
            dismiss()
        } label: {
            Text("Dismiss")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 60)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(accent)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Loading / Error States

    private var loadingView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                greetingSection

                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading weather…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(30)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
            .padding(.horizontal, 20)

            Spacer()

            dismissButton
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .onAppear {
            // Auto-dismiss after 5s if still loading
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if case .loading = weatherService.state {
                    dismiss()
                } else if case .idle = weatherService.state {
                    dismiss()
                }
            }
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                greetingSection

                VStack(spacing: 12) {
                    Image(systemName: "icloud.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)

                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(30)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
            .padding(.horizontal, 20)

            Spacer()

            dismissButton
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
    }

    // MARK: - Background

    private func wallpaperBackground(_ image: UIImage) -> some View {
        let settings = DeviceSettings.shared

        // Position with the shared home-theme wallpaper props for the appearance the
        // image was loaded for. `wallpaperIsDark` (not the forced-dark colorScheme)
        // drives this so the card matches the home list / alarm screen.
        let scale = wallpaperIsDark ? settings.homeDarkWallpaperScale : settings.homeWallpaperScale
        let offsetX = wallpaperIsDark ? settings.homeDarkWallpaperOffsetX : settings.homeWallpaperOffsetX
        let offsetY = wallpaperIsDark ? settings.homeDarkWallpaperOffsetY : settings.homeWallpaperOffsetY
        let dimming = wallpaperIsDark ? settings.homeDarkWallpaperDimming : settings.homeWallpaperDimming

        return ZStack {
            GeometryReader { geo in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(scale)
                    .offset(x: offsetX, y: offsetY)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                Color.black.opacity(dimming)
            }
        }
    }

    private var backgroundGradient: some View {
        AnimatedWeatherGradient(
            colors: weatherAccentColors
        )
    }

    /// Glass style for weather cards.
    private var weatherGlass: Glass {
        .regular
    }

    private var weatherAccentColors: [Color] {
        guard case .loaded(let current, _) = weatherService.state else {
            return [.blue.opacity(0.15), .cyan.opacity(0.1)]
        }

        switch current.condition {
        case .clear, .mostlyClear:
            return [.orange.opacity(0.1), .cyan.opacity(0.1)]
        case .cloudy, .mostlyCloudy, .partlyCloudy:
            return [.gray.opacity(0.15), .blue.opacity(0.1)]
        case .rain, .drizzle, .heavyRain:
            return [.blue.opacity(0.2), .indigo.opacity(0.15)]
        case .snow, .flurries, .heavySnow, .sleet:
            return [.white.opacity(0.15), .cyan.opacity(0.1)]
        case .thunderstorms, .strongStorms:
            return [.purple.opacity(0.15), .indigo.opacity(0.15)]
        case .foggy, .haze, .smoky:
            return [.gray.opacity(0.15), .gray.opacity(0.1)]
        case .windy, .breezy:
            return [.teal.opacity(0.15), .mint.opacity(0.1)]
        default:
            return [.blue.opacity(0.15), .cyan.opacity(0.1)]
        }
    }

    // MARK: - Helpers

    private func dismiss() {
        autoDismissTask?.cancel()
        onDismiss()
    }

    private func startAutoDismiss() {
        autoDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled {
                dismiss()
            }
        }
    }
}
// MARK: - Animated Temperature Text

/// Counts up from 0 to the target temperature value on appear.
private struct AnimatedTemperatureText: View {
    let value: String
    let font: Font

    @State private var displayedValue: Double = 0
    @State private var hasAppeared = false

    /// Parse the numeric portion from a formatted string like "72°"
    private var targetValue: Double {
        let digits = value.filter { $0.isNumber || $0 == "-" || $0 == "." }
        return Double(digits) ?? 0
    }

    /// The suffix after the number (e.g. "°")
    private var suffix: String {
        String(value.drop(while: { $0.isNumber || $0 == "-" || $0 == "." || $0 == " " }))
    }

    var body: some View {
        Text("\(Int(displayedValue))\(suffix)")
            .font(font)
            .minimumScaleFactor(0.6)
            .monospacedDigit()
            .contentTransition(.numericText(value: displayedValue))
            .onAppear {
                guard !hasAppeared else { return }
                hasAppeared = true
                withAnimation(.easeOut(duration: 1.2)) {
                    displayedValue = targetValue
                }
            }
    }
}

// MARK: - Animated Weather Gradient Background

/// Time-of-day and condition-aware animated gradient background.
/// Colors slowly drift by animating the gradient start/end points.
private struct AnimatedWeatherGradient: View {
    let colors: [Color]

    @State private var animateGradient = false

    /// Base tint from time of day — warm for morning, cool for night.
    private var timeOfDayTint: Color {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<8:   return .orange.opacity(0.12)   // Early morning — warm dawn
        case 8..<11:  return .yellow.opacity(0.08)    // Morning — bright
        case 11..<15: return .white.opacity(0.05)     // Midday — neutral
        case 15..<18: return .orange.opacity(0.1)     // Afternoon — golden
        case 18..<21: return .indigo.opacity(0.12)    // Evening — cool
        default:      return .blue.opacity(0.15)      // Night — deep blue
        }
    }

    /// Build the full gradient color array by blending condition colors with time-of-day.
    private var gradientColors: [Color] {
        [timeOfDayTint] + colors + [timeOfDayTint]
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)

            // Primary animated gradient — drifts diagonally
            LinearGradient(
                colors: gradientColors,
                startPoint: animateGradient ? .topLeading : .bottomLeading,
                endPoint: animateGradient ? .bottomTrailing : .topTrailing
            )
            .opacity(0.5)

            // Secondary gradient layer for depth — drifts in the opposite direction
            RadialGradient(
                colors: [
                    colors.first?.opacity(0.15) ?? .clear,
                    .clear
                ],
                center: animateGradient ? .topTrailing : .bottomLeading,
                startRadius: 100,
                endRadius: 500
            )
            .opacity(0.6)
        }
        .onAppear {
            withAnimation(
                .easeInOut(duration: 8)
                .repeatForever(autoreverses: true)
            ) {
                animateGradient = true
            }
        }
    }
}

// MARK: - Reusable Apple Weather Attribution

/// Apple Weather (WeatherKit) attribution: the Apple Weather trademark mark + the legal
/// "Weather data sources" link. Loads the attribution from the WeatherKit API on appear
/// (no location or weather query needed), and picks the light/dark mark for the current
/// color scheme so it stays legible on any background. Reused wherever the weather feature
/// is surfaced — e.g. below the Morning Weather toggle in the alarm editor — so the
/// required attribution is easy to find.
struct AppleWeatherAttributionView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var weatherService = HaWakeWeatherService.shared
    private var accent: Color { DeviceSettings.shared.appAccent(for: colorScheme) }

    /// Apple's legal attribution page, used as a fallback if the API attribution hasn't
    /// loaded. This is the exact URL Apple cites and that the API's `legalPageURL` returns
    /// (it 308-redirects to developer.apple.com/weatherkit/data-source-attribution/).
    private let fallbackLegalURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

    var body: some View {
        // Prefer the API's legal URL; fall back to Apple's cited URL if not loaded yet.
        let legalURL = weatherService.attribution?.legalPageURL ?? fallbackLegalURL

        VStack(alignment: .leading, spacing: 6) {
            if let attribution = weatherService.attribution {
                let markURL = colorScheme == .dark
                    ? attribution.combinedMarkDarkURL
                    : attribution.combinedMarkLightURL

                AsyncImage(url: markURL) { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(height: 12)
                } placeholder: {
                    EmptyView()
                }
            }

            // Styled to read unmistakably as a tappable link — tinted, underlined, with an
            // external-link arrow. Plain secondary text wasn't obviously clickable.
            Link(destination: legalURL) {
                HStack(spacing: 3) {
                    Text("Weather data sources")
                        .underline()
                    Image(systemName: "arrow.up.right")
                        .imageScale(.small)
                }
                .font(.caption2.weight(.semibold))
            }
            .tint(accent)
        }
        .task { await weatherService.loadAttributionIfNeeded() }
    }
}

