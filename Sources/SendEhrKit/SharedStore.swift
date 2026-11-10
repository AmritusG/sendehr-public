// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Amrit Rosell
//
// This file is part of SendEhr.
//
// SendEhr is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.
//
// SendEhr is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
// FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
// details.
//
// You should have received a copy of the GNU General Public License along
// with SendEhr.  If not, see <https://www.gnu.org/licenses/>.

import Foundation

/// What the host app publishes for the Finder extension (App Group file).
public struct CacheState: Codable, Equatable, Sendable {
    public var status: ArenaStatus
    public var snapshot: CompositionSnapshot?
    public var hostPID: Int32
    public var writtenAt: Date
    /// When the host last received the composition (the Finder menu's "Updated n s ago").
    public var updatedAt: Date?

    public init(status: ArenaStatus, snapshot: CompositionSnapshot?, hostPID: Int32, writtenAt: Date = Date(), updatedAt: Date? = nil) {
        self.status = status; self.snapshot = snapshot; self.hostPID = hostPID; self.writtenAt = writtenAt
        self.updatedAt = updatedAt
    }
}

/// A menu pick sent from the Finder extension to the host app: a load
/// (`paths` = selected files and folders), or a settings change (`setting`
/// set, `paths` empty) - the host owns settings.json, so the extension never
/// writes it.
public struct LoadRequest: Codable, Equatable, Sendable {
    public var id: UUID
    public var paths: [String]
    public var destination: Destination
    public var replaceConfirmed: Bool
    public var label: String
    public var createdAt: Date
    public var setting: SettingChange?
    /// New-layer picks: the layer indices the menu showed (from the cache at
    /// menu time), so the host can log when Arena's real indices differ.
    public var expectedLayers: ClosedRange<Int>?

    public init(id: UUID = UUID(), paths: [String], destination: Destination, replaceConfirmed: Bool, label: String,
                createdAt: Date = Date(), setting: SettingChange? = nil, expectedLayers: ClosedRange<Int>? = nil) {
        self.id = id; self.paths = paths; self.destination = destination
        self.replaceConfirmed = replaceConfirmed; self.label = label; self.createdAt = createdAt; self.setting = setting
        self.expectedLayers = expectedLayers
    }

    public static func settingChange(_ change: SettingChange) -> LoadRequest {
        LoadRequest(paths: [], destination: .newLayer, replaceConfirmed: false, label: change.logLine, setting: change)
    }
}

/// Files in the App Group container shared by SendEhr.app and its Finder
/// extension. Every write is atomic (write-then-rename).
public struct SharedStore: Sendable {
    public static let appGroup = "3A3L2C6DFB.com.amritus.sendehr"
    /// Folder inside the App Group container.
    public static let appGroupFolder = "SendEhr"
    /// Folder under Application Support holding one folder per host bundle id (`SendToArenaController.shared`).
    public static let kitFolder = "SendEhrKit"
    /// Posted (no userInfo: sandboxed senders lose it) after a request file is written.
    public static let requestNotification = "com.amritus.sendehr.request"
    /// Posted (no userInfo) by the extension when it shows a menu while the cache
    /// says disconnected: the host tries to connect at once instead of waiting for its backoff.
    /// In On Demand / Interval mode it is posted on every Finder menu open (the host fetches, throttled).
    public static let wakeNotification = "com.amritus.sendehr.wake"
    /// Posted (no userInfo) by the Finder menu's Refresh item: the host fetches now.
    public static let refreshNotification = "com.amritus.sendehr.refresh"
    /// The host heartbeat (cache rewrite or mtime touch); older than this means "SendEhr is not running".
    public static let staleAfter: TimeInterval = 25

    public let root: URL

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: requestsDir, withIntermediateDirectories: true)
    }

    /// The App Group container, or nil when the process lacks the entitlement.
    public static func appGroupStore() -> SharedStore? {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        return SharedStore(root: url.appendingPathComponent(appGroupFolder, isDirectory: true))
    }

    public var cacheURL: URL { root.appendingPathComponent("cache.json") }
    public var settingsURL: URL { root.appendingPathComponent("settings.json") }
    public var recentsURL: URL { root.appendingPathComponent("recents.json") }
    public var requestsDir: URL { root.appendingPathComponent("requests", isDirectory: true) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }()

    func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(value).write(to: url, options: .atomic)
    }

    func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }

    public func writeCache(_ c: CacheState) throws { try write(c, to: cacheURL) }
    /// Heartbeat without re-encoding: bumps the cache file's modification date.
    public func touchCache(_ date: Date = Date()) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: cacheURL.path)
    }
    public func readCache() -> CacheState? { read(CacheState.self, from: cacheURL) }

    public func writeSettings(_ s: SendEhrSettings) throws { try write(s, to: settingsURL) }
    public func readSettings() -> SendEhrSettings { read(SendEhrSettings.self, from: settingsURL) ?? .default }

    public func writeRecents(_ r: [RecentTarget]) throws { try write(r, to: recentsURL) }
    public func readRecents() -> [RecentTarget] { read([RecentTarget].self, from: recentsURL) ?? [] }

    public func submit(_ request: LoadRequest) throws {
        try write(request, to: requestsDir.appendingPathComponent("\(request.id.uuidString).json"))
    }

    /// Takes (reads and deletes) all pending requests, oldest first.
    public func takeRequests() -> [LoadRequest] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: requestsDir, includingPropertiesForKeys: nil)) ?? []
        var out: [LoadRequest] = []
        for url in urls where url.pathExtension == "json" {
            if let r = read(LoadRequest.self, from: url) { out.append(r) }
            try? FileManager.default.removeItem(at: url)
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    /// True when the cache was written recently by a live host.
    public func hostIsAlive(_ cache: CacheState?, now: Date = Date()) -> Bool {
        guard let cache else { return false }
        let touched = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate]) as? Date
        return now.timeIntervalSince(max(cache.writtenAt, touched ?? .distantPast)) < Self.staleAfter
    }
}
