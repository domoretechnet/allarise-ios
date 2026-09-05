//
//  RadioStation.swift
//  HaWake Alarm V2
//
//  Model for an internet radio station from the radio-browser.info
//  community directory. Stored favorites keep a snapshot of the stream
//  URL so playback (including alarm playback) never depends on the
//  directory API being reachable.
//

import Foundation

struct RadioStation: Codable, Identifiable, Equatable, Hashable {
    /// radio-browser.info stationuuid — stable across servers
    let id: String
    var name: String
    /// Direct stream URL (url_resolved from the API — playlists already unwrapped)
    var streamURL: String
    var faviconURL: String?
    var country: String
    var tags: String
    var codec: String
    var bitrate: Int

    /// Favicon URL upgraded to https. ATS blocks plain-http image downloads
    /// (NSAllowsArbitraryLoadsForMedia only covers AVPlayer streams, not
    /// AsyncImage/URLSession) — hosts without TLS fail the same as before,
    /// showing the placeholder.
    var secureFaviconURL: URL? {
        guard let faviconURL, !faviconURL.isEmpty else { return nil }
        if faviconURL.lowercased().hasPrefix("http://") {
            return URL(string: "https://" + faviconURL.dropFirst("http://".count))
        }
        return URL(string: faviconURL)
    }

    /// Short subtitle for list rows, e.g. "USA · pop, top 40 · 128kbps"
    var subtitle: String {
        var parts: [String] = []
        if !country.isEmpty { parts.append(country) }
        let trimmedTags = tags.split(separator: ",").prefix(3).joined(separator: ", ")
        if !trimmedTags.isEmpty { parts.append(trimmedTags) }
        if bitrate > 0 { parts.append("\(bitrate)kbps") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - radio-browser.info API

/// Minimal client for the radio-browser.info community API.
/// Guidelines followed (https://api.radio-browser.info):
/// - Pick a concrete API server instead of hammering the round-robin alias
/// - Send a descriptive User-Agent
/// - Report a station click when playback starts so popularity rankings work
final class RadioBrowserAPI: Sendable {
    static let shared = RadioBrowserAPI()

    /// Fallback mirrors used when the server-discovery call fails.
    private static let fallbackServers = [
        "de1.api.radio-browser.info",
        "de2.api.radio-browser.info",
        "fi1.api.radio-browser.info",
    ]

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = [
            "User-Agent": "AllariseAlarm/5.0 (iOS alarm clock; radio feature)",
            "Accept": "application/json",
        ]
        return URLSession(configuration: config)
    }()

    /// Cached API host for this app session (protected by the actor below).
    private let serverCache = ServerCache()

    private actor ServerCache {
        var host: String?
        func get() -> String? { host }
        func set(_ value: String) { host = value }
    }

    enum RadioAPIError: Error {
        case invalidURL
        case httpError(Int)
    }

    // MARK: Server discovery

    private struct ServerEntry: Decodable {
        let name: String
    }

    /// Resolve (and cache) a concrete API server. Falls back to a hardcoded
    /// mirror when discovery fails — search should still work offline-adjacent.
    private func apiHost() async -> String {
        if let cached = await serverCache.get() { return cached }
        var host = Self.fallbackServers.randomElement() ?? Self.fallbackServers[0]
        if let url = URL(string: "https://all.api.radio-browser.info/json/servers"),
           let (data, response) = try? await session.data(from: url),
           let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
           let entries = try? JSONDecoder().decode([ServerEntry].self, from: data) {
            let names = Set(entries.map(\.name))
            if let picked = names.randomElement(), !picked.isEmpty {
                host = picked
            }
        }
        await serverCache.set(host)
        return host
    }

    // MARK: Station queries

    private struct APIStation: Decodable {
        let stationuuid: String
        let name: String
        let url_resolved: String
        let favicon: String
        let country: String
        let tags: String
        let codec: String
        let bitrate: Int
    }

    /// Rate limits and outages are per-mirror, so a failed request gets one
    /// retry against a different server before surfacing the error.
    private func stations(path: String, query: [URLQueryItem]) async throws -> [RadioStation] {
        do {
            return try await stationsAttempt(host: await apiHost(), path: path, query: query)
        } catch {
            guard !Task.isCancelled else { throw error }
            return try await stationsAttempt(host: await rotateHost(), path: path, query: query)
        }
    }

    /// Swap the cached mirror for a different one (used after a failure).
    private func rotateHost() async -> String {
        let current = await serverCache.get()
        let candidates = Self.fallbackServers.filter { $0 != current }
        let host = candidates.randomElement() ?? Self.fallbackServers[0]
        await serverCache.set(host)
        return host
    }

    private func stationsAttempt(host: String, path: String, query: [URLQueryItem]) async throws -> [RadioStation] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query
        guard let url = components.url else { throw RadioAPIError.invalidURL }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw RadioAPIError.httpError(0) }
        guard (200...299).contains(http.statusCode) else { throw RadioAPIError.httpError(http.statusCode) }

        let decoded = try JSONDecoder().decode([APIStation].self, from: data)
        return decoded.compactMap { api in
            let trimmedName = api.name.trimmingCharacters(in: .whitespacesAndNewlines)
            // http:// is allowed (NSAllowsArbitraryLoadsForMedia covers AVPlayer),
            // but AVPlayer can't decode OGG/Opus — skip those rather than
            // showing rows that fail on tap.
            let codec = api.codec.uppercased()
            guard !trimmedName.isEmpty,
                  api.url_resolved.lowercased().hasPrefix("http"),
                  !codec.contains("OGG"), !codec.contains("OPUS") else { return nil }
            return RadioStation(
                id: api.stationuuid,
                name: trimmedName,
                streamURL: api.url_resolved,
                faviconURL: api.favicon.isEmpty ? nil : api.favicon,
                country: api.country,
                tags: api.tags,
                codec: api.codec,
                bitrate: api.bitrate
            )
        }
    }

    /// Search stations by name, most-listened first. `offset` pages through
    /// results for infinite scroll.
    func search(name: String, limit: Int = 50, offset: Int = 0) async throws -> [RadioStation] {
        try await stations(path: "/json/stations/search", query: [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "clickcount"),
            URLQueryItem(name: "reverse", value: "true"),
        ])
    }

    /// Most-listened stations — optionally scoped to a country and/or a
    /// state/region (radio-browser's `state` field, e.g. "Michigan").
    /// `offset` pages through results for infinite scroll.
    func popular(countryCode: String? = nil, state: String? = nil, limit: Int = 50, offset: Int = 0) async throws -> [RadioStation] {
        var query = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "clickcount"),
            URLQueryItem(name: "reverse", value: "true"),
        ]
        if let countryCode {
            query.append(URLQueryItem(name: "countrycode", value: countryCode))
        }
        if let state {
            query.append(URLQueryItem(name: "state", value: state))
        }
        return try await stations(path: "/json/stations/search", query: query)
    }

    /// Fire-and-forget click report when a station starts playing —
    /// keeps the community popularity rankings honest (API etiquette).
    func reportClick(stationID: String) {
        Task {
            let host = await apiHost()
            guard let url = URL(string: "https://\(host)/json/url/\(stationID)") else { return }
            _ = try? await session.data(from: url)
        }
    }
}
