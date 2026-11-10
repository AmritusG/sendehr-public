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

/// How an occupied slot is offered in the menu.
public enum OccupiedSlotMode: String, Codable, CaseIterable, Sendable {
    /// Occupied slots are normal items; loading over one asks first (default).
    case ask
    /// Occupied slots open a submenu with an explicit "Replace" item; no dialog.
    case replaceItem
}

/// Which new layers Trigger After Load connects when one pick makes several
/// (Folders as New Layers). One new layer is always triggered either way.
public enum TriggerScope: String, Codable, CaseIterable, Sendable {
    /// The first clip of every new layer (default).
    case allNewLayers
    /// Only the first clip of the top-most new layer.
    case topLayerOnly

    public var title: String {
        switch self {
        case .allNewLayers: return "All New Layers"
        case .topLayerOnly: return "Top Layer Only"
        }
    }

    /// Whether the new layer at `position` (0 = top-most) is triggered.
    public func triggers(position: Int) -> Bool { self == .allNewLayers || position == 0 }
}

/// How the composition reaches the menus. Every load re-reads a fresh
/// composition before acting, so this only decides how current the menu labels are.
public enum ArenaUpdateMode: String, Codable, CaseIterable, Sendable {
    /// Websocket open: Arena pushes the full composition on every change (default).
    case live
    /// No websocket: one REST fetch when a menu opens (or Refresh).
    case onDemand
    /// No websocket: a REST fetch every `updateInterval` seconds, plus on menu open.
    case interval

    public var title: String {
        switch self {
        case .live: return "Live"
        case .onDemand: return "On Demand"
        case .interval: return "Interval"
        }
    }

    /// The interval choices offered in the menus and the Settings window (seconds).
    public static let intervals = [15, 30, 60, 120, 300]

    public static func intervalTitle(_ seconds: Int) -> String {
        seconds < 60 || seconds % 60 != 0 ? "\(seconds) s" : "\(seconds / 60) min"
    }
}

public struct ArenaEndpoint: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String = "localhost", port: Int = 8080) {
        self.host = host
        self.port = port
    }

    public var isLocal: Bool { ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) }
    public var apiBase: URL { URL(string: "http://\(host):\(port)/api/v1")! }
}

/// Settings shared by the host app, the Finder extension and MaCrate.
/// Decoding tolerates missing keys (older settings files keep their values).
public struct SendEhrSettings: Codable, Equatable, Sendable {
    public var endpoint: ArenaEndpoint
    public var remaps: [PathRemap]
    public var occupiedSlotMode: OccupiedSlotMode
    /// Connect (trigger) the first loaded clip. Never on by default.
    public var triggerAfterLoad: Bool
    /// With Trigger After Load on and several new layers: all, or the top one only.
    public var triggerScope: TriggerScope
    /// Empty columns listed past the deck's last occupied column before the
    /// rest fold into "More Columns" submenus.
    public var extraEmptyColumns: Int
    /// Order of a multi-file selection / expanded folder in consecutive columns.
    public var sortKey: SortKey
    public var sortAscending: Bool
    /// Folders expand recursively when on; only their direct files when off.
    public var includeSubfolders: Bool
    /// Ask once before loading when folders expand to more files than this.
    public var largeFolderThreshold: Int
    /// Live websocket, on-demand fetch, or a fetch every `updateInterval` seconds.
    public var updateMode: ArenaUpdateMode
    /// Seconds between fetches in `.interval` mode.
    public var updateInterval: Int
    /// True once the user picked a mode (menu or Settings window). False: the
    /// host's default applies at start (an older file without the key: false for
    /// Live, true for On Demand / Interval, which only a pick could set),
    /// see `SendToArenaController.start(defaultUpdateMode:)`.
    public var updateModeChosen: Bool

    public init(endpoint: ArenaEndpoint = ArenaEndpoint(), remaps: [PathRemap] = [],
                occupiedSlotMode: OccupiedSlotMode = .ask, triggerAfterLoad: Bool = false, triggerScope: TriggerScope = .allNewLayers,
                extraEmptyColumns: Int = 8, sortKey: SortKey = .name, sortAscending: Bool = true,
                includeSubfolders: Bool = false, largeFolderThreshold: Int = 50,
                updateMode: ArenaUpdateMode = .live, updateInterval: Int = 60, updateModeChosen: Bool = false) {
        self.endpoint = endpoint
        self.remaps = remaps
        self.occupiedSlotMode = occupiedSlotMode
        self.triggerAfterLoad = triggerAfterLoad
        self.triggerScope = triggerScope
        self.extraEmptyColumns = extraEmptyColumns
        self.sortKey = sortKey
        self.sortAscending = sortAscending
        self.includeSubfolders = includeSubfolders
        self.largeFolderThreshold = largeFolderThreshold
        self.updateMode = updateMode
        self.updateInterval = updateInterval
        self.updateModeChosen = updateModeChosen
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SendEhrSettings()
        endpoint = try c.decodeIfPresent(ArenaEndpoint.self, forKey: .endpoint) ?? d.endpoint
        remaps = try c.decodeIfPresent([PathRemap].self, forKey: .remaps) ?? d.remaps
        occupiedSlotMode = try c.decodeIfPresent(OccupiedSlotMode.self, forKey: .occupiedSlotMode) ?? d.occupiedSlotMode
        triggerAfterLoad = try c.decodeIfPresent(Bool.self, forKey: .triggerAfterLoad) ?? d.triggerAfterLoad
        triggerScope = try c.decodeIfPresent(TriggerScope.self, forKey: .triggerScope) ?? d.triggerScope
        extraEmptyColumns = try c.decodeIfPresent(Int.self, forKey: .extraEmptyColumns) ?? d.extraEmptyColumns
        sortKey = try c.decodeIfPresent(SortKey.self, forKey: .sortKey) ?? d.sortKey
        sortAscending = try c.decodeIfPresent(Bool.self, forKey: .sortAscending) ?? d.sortAscending
        includeSubfolders = try c.decodeIfPresent(Bool.self, forKey: .includeSubfolders) ?? d.includeSubfolders
        largeFolderThreshold = try c.decodeIfPresent(Int.self, forKey: .largeFolderThreshold) ?? d.largeFolderThreshold
        updateMode = try c.decodeIfPresent(ArenaUpdateMode.self, forKey: .updateMode) ?? d.updateMode
        updateInterval = max(1, try c.decodeIfPresent(Int.self, forKey: .updateInterval) ?? d.updateInterval)
        // Pre-0.1.7 files have no flag; there every mode other than Live came from a pick (0.1.6 default was Live).
        updateModeChosen = try c.decodeIfPresent(Bool.self, forKey: .updateModeChosen) ?? (updateMode != .live)
    }

    public static let `default` = SendEhrSettings()

    /// "Live", "On Demand", "Every 60 s".
    public var updateDescription: String {
        updateMode == .interval ? "Every \(ArenaUpdateMode.intervalTitle(updateInterval))" : updateMode.title
    }

    public var sortDescription: String { "\(sortKey.title) \(sortAscending ? "\u{2191}" : "\u{2193}")" }

    /// One line of the load-relevant settings, logged per request and on Apply.
    public var logSummary: String {
        "sort \(sortDescription), subfolders \(includeSubfolders ? "on" : "off"), ask over \(largeFolderThreshold), "
            + "trigger \(triggerAfterLoad ? "on" : "off") (\(triggerScope.title))"
    }
}

/// One settings change picked from a menu (Finder extension -> host request,
/// or applied directly by `SendToArenaController`).
public enum SettingChange: Hashable, Codable, Sendable {
    case sortKey(SortKey)
    case sortAscending(Bool)
    case triggerAfterLoad(Bool)
    case triggerScope(TriggerScope)
    case includeSubfolders(Bool)
    case updateMode(ArenaUpdateMode)
    /// Picks an interval and switches to `.interval`.
    case updateInterval(Int)

    public func applied(to s: SendEhrSettings) -> SendEhrSettings {
        var s = s
        switch self {
        case let .sortKey(k): s.sortKey = k
        case let .sortAscending(a): s.sortAscending = a
        case let .triggerAfterLoad(on): s.triggerAfterLoad = on
        case let .triggerScope(scope): s.triggerScope = scope
        case let .includeSubfolders(on): s.includeSubfolders = on
        case let .updateMode(m): s.updateMode = m; s.updateModeChosen = true
        case let .updateInterval(n): s.updateInterval = max(1, n); s.updateMode = .interval; s.updateModeChosen = true
        }
        return s
    }

    public var logLine: String {
        switch self {
        case let .sortKey(k): return "Sort by \(k.title)"
        case let .sortAscending(a): return "Sort \(a ? "ascending" : "descending")"
        case let .triggerAfterLoad(on): return "Trigger After Load \(on ? "ON" : "OFF")"
        case let .triggerScope(scope): return "Trigger Scope \(scope.title)"
        case let .includeSubfolders(on): return "Include Subfolders \(on ? "ON" : "OFF")"
        case let .updateMode(m): return "Arena Updates \(m.title)"
        case let .updateInterval(n): return "Arena Updates every \(ArenaUpdateMode.intervalTitle(n))"
        }
    }
}

/// One remembered pick, shown under "Recent" (last 5).
public struct RecentTarget: Codable, Hashable, Sendable {
    public var destination: Destination
    public var label: String
    public var date: Date

    public init(destination: Destination, label: String, date: Date = Date()) {
        self.destination = destination
        self.label = label
        self.date = date
    }

    public static let limit = 5

    public static func pushing(_ new: RecentTarget, onto list: [RecentTarget]) -> [RecentTarget] {
        guard new.destination.layerID != nil else { return list }   // new layers are not targets to repeat
        var out = list.filter { $0.destination != new.destination }
        out.insert(new, at: 0)
        return Array(out.prefix(limit))
    }
}
