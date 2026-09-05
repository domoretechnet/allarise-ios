//
//  NowPlayingArtwork.swift
//  HaWake Alarm V2
//
//  Shared app-icon artwork for MPNowPlayingInfoCenter so the Dynamic
//  Island / Lock Screen player shows the Allarise icon during sleep-sound
//  and radio playback instead of a generic placeholder.
//
//  Note for future reference: the Dynamic Island's animated playing-wave bars
//  are tinted by iOS from the DOMINANT COLOR OF THIS ARTWORK — there is no API
//  to set them directly. Theming the waves therefore means rendering themed
//  artwork, which was tried and deliberately reverted: the plain app icon is
//  the wanted look.
//

import MediaPlayer
import UIKit

enum NowPlayingArtwork {
    /// Posted when playback managers should refresh their Now Playing info.
    /// Currently unused for theming (artwork is a fixed asset), but retained
    /// as the refresh channel for anything that invalidates published info.
    static let refreshNotification = Notification.Name("NowPlayingArtworkRefresh")

    /// App icon as media artwork; nil if the asset is missing.
    /// Computed per call — UIImage(named:) is system-cached, and avoiding a
    /// stored MPMediaItemArtwork sidesteps Sendable issues across managers.
    static func appIcon() -> MPMediaItemArtwork? {
        guard let icon = UIImage(named: "AppIconDisplay") else { return nil }
        return MPMediaItemArtwork(boundsSize: icon.size) { _ in icon }
    }
}
