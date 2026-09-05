//
//  AudioConverter.swift
//  HaWake Alarm V2
//
//  Converts audio files to WAV (16-bit PCM, 44100 Hz) for UNNotificationSound compatibility.
//

import AVFoundation
import Foundation

enum AudioConverter {
    enum ConversionError: LocalizedError {
        case fileNotReadable
        case conversionFailed(String)
        case outputTooLarge(Int64)

        var errorDescription: String? {
            switch self {
            case .fileNotReadable:
                return "The audio file could not be read."
            case .conversionFailed(let reason):
                return "Audio conversion failed: \(reason)"
            case .outputTooLarge(let bytes):
                let mb = Double(bytes) / 1_000_000
                return String(format: "Converted file is too large (%.1f MB). Maximum is 10 MB.", mb)
            }
        }
    }

    /// Supported import formats
    static let supportedExtensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "caf", "flac", "aac"]

    /// Converts the source audio file to 16-bit PCM WAV at 44100 Hz.
    /// Returns the URL of the converted file written to `outputURL`.
    static func convertToWAV(source: URL, outputURL: URL) throws -> URL {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        let sourceFile: AVAudioFile
        do {
            sourceFile = try AVAudioFile(forReading: source)
        } catch {
            throw ConversionError.fileNotReadable
        }

        // Target format: 16-bit PCM WAV, 44100 Hz, mono or stereo (match source channels)
        let channels = min(sourceFile.processingFormat.channelCount, 2)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 44100,
            channels: channels,
            interleaved: true
        ) else {
            throw ConversionError.conversionFailed("Could not create output format")
        }

        // Read source into a processing buffer
        let frameCount = AVAudioFrameCount(sourceFile.length)
        guard let readBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFile.processingFormat,
            frameCapacity: frameCount
        ) else {
            throw ConversionError.conversionFailed("Could not allocate read buffer")
        }
        try sourceFile.read(into: readBuffer)

        // Convert via AVAudioConverter
        guard let converter = AVAudioConverter(from: sourceFile.processingFormat, to: outputFormat) else {
            throw ConversionError.conversionFailed("Could not create audio converter")
        }

        // Estimate output frame count based on sample rate ratio
        let ratio = 44100.0 / sourceFile.processingFormat.sampleRate
        let estimatedFrames = AVAudioFrameCount(Double(frameCount) * ratio) + 1024
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: estimatedFrames
        ) else {
            throw ConversionError.conversionFailed("Could not allocate output buffer")
        }

        var conversionError: NSError?
        let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            outStatus.pointee = .haveData
            return readBuffer
        }

        if status == .error, let error = conversionError {
            throw ConversionError.conversionFailed(error.localizedDescription)
        }

        // Write output WAV
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        try outputFile.write(from: convertedBuffer)

        // Check output size (10 MB limit for alarm tones)
        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0
        if fileSize > 10_000_000 {
            try? FileManager.default.removeItem(at: outputURL)
            throw ConversionError.outputTooLarge(fileSize)
        }

        return outputURL
    }
}
