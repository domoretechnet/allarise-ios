//
//  RadioFaviconCache.swift
//  HaWake Alarm V2
//
//  A small, bounded cache for station artwork. Directory favicons are refreshed
//  after 24 hours, with stale artwork used as a fallback when refresh fails.
//

import CryptoKit
import Foundation
import SwiftUI
import UIKit

actor RadioFaviconCache {
    static let shared = RadioFaviconCache()

    private struct MemoryEntry {
        let data: Data
        let fetchedAt: Date
    }

    private let lifetime: TimeInterval = 24 * 60 * 60
    private let maximumMemoryEntries = 100
    private let maximumMemoryBytes = 5 * 1_024 * 1_024
    private let maximumDiskEntries = 300
    private let maximumDiskBytes = 20 * 1_024 * 1_024
    private let maximumImageBytes = 1 * 1_024 * 1_024

    private let fileManager = FileManager.default
    private let directory: URL
    private let session: URLSession
    private var memory: [URL: MemoryEntry] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("RadioFavicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// Drop the in-memory tier under memory pressure. The disk tier is
    /// untouched, so entries are re-read rather than re-downloaded.
    func purgeMemory() {
        memory.removeAll()
    }

    func data(for url: URL) async -> Data? {
        let now = Date()
        if let entry = memory[url], now.timeIntervalSince(entry.fetchedAt) < lifetime {
            return entry.data
        }

        let fileURL = cachedFileURL(for: url)
        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
        let fetchedAt = values?.contentModificationDate
        let diskData = try? Data(contentsOf: fileURL, options: .mappedIfSafe)

        if let fetchedAt, let diskData,
           now.timeIntervalSince(fetchedAt) < lifetime,
           validImageData(diskData) {
            storeInMemory(diskData, for: url, fetchedAt: fetchedAt)
            return diskData
        }

        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            let (downloaded, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  downloaded.count <= maximumImageBytes,
                  validImageData(downloaded) else {
                return staleFallback(diskData, for: url, fetchedAt: fetchedAt)
            }

            try downloaded.write(to: fileURL, options: .atomic)
            storeInMemory(downloaded, for: url, fetchedAt: now)
            pruneDiskCache()
            return downloaded
        } catch {
            return staleFallback(diskData, for: url, fetchedAt: fetchedAt)
        }
    }

    private func staleFallback(_ data: Data?, for url: URL, fetchedAt: Date?) -> Data? {
        guard let data, validImageData(data) else { return nil }
        storeInMemory(data, for: url, fetchedAt: fetchedAt ?? .distantPast)
        return data
    }

    private func validImageData(_ data: Data) -> Bool {
        !data.isEmpty && data.count <= maximumImageBytes && UIImage(data: data) != nil
    }

    private func storeInMemory(_ data: Data, for url: URL, fetchedAt: Date) {
        memory[url] = MemoryEntry(data: data, fetchedAt: fetchedAt)
        while memory.count > maximumMemoryEntries
                || memory.values.reduce(0, { $0 + $1.data.count }) > maximumMemoryBytes,
              let oldestURL = memory.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
            memory.removeValue(forKey: oldestURL)
        }
    }

    private func cachedFileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("favicon")
    }

    private func pruneDiskCache() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        let entries = files.compactMap { url -> (url: URL, date: Date, size: Int)? in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        .sorted { $0.date > $1.date }

        var keptBytes = 0
        for (index, entry) in entries.enumerated() {
            let exceedsLimit = index >= maximumDiskEntries || keptBytes + entry.size > maximumDiskBytes
            if exceedsLimit {
                try? fileManager.removeItem(at: entry.url)
            } else {
                keptBytes += entry.size
            }
        }
    }
}

struct RadioFaviconView: View {
    let url: URL

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "radio")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            image = nil
            guard let data = await RadioFaviconCache.shared.data(for: url),
                  !Task.isCancelled else { return }
            image = UIImage(data: data)
        }
    }
}
