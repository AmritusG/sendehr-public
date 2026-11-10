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

/// The small, menu-ready view of Arena's current deck. Built from the 29 MB
/// `GET /composition` (or a websocket composition push) and cached as compact
/// JSON so a Finder Sync `menu(for:)` can render it instantly.
public struct CompositionSnapshot: Codable, Equatable, Sendable {
    public var compositionName: String
    public var deckName: String
    public var layers: [LayerInfo]     // index 0 = Arena layer 1 (bottom)
    public var columns: [ColumnInfo]   // index 0 = column 1

    public init(compositionName: String, deckName: String, layers: [LayerInfo], columns: [ColumnInfo]) {
        self.compositionName = compositionName
        self.deckName = deckName
        self.layers = layers
        self.columns = columns
    }

    /// Same menu layout: names, ids, occupancy and clip names. Play state
    /// (Connected / Disconnected, the menu's play mark) is ignored: Arena's
    /// autopilot changes it on every push.
    public static func sameMenu(_ a: CompositionSnapshot?, _ b: CompositionSnapshot?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        guard a.compositionName == b.compositionName, a.deckName == b.deckName, a.columns == b.columns,
              a.layers.count == b.layers.count else { return false }
        for (la, lb) in zip(a.layers, b.layers) {
            guard la.index == lb.index, la.id == lb.id, la.rawName == lb.rawName, la.nameParamID == lb.nameParamID,
                  la.slots.count == lb.slots.count else { return false }
            for (sa, sb) in zip(la.slots, lb.slots) where sa.clipID != sb.clipID || sa.clipName != sb.clipName
                || sa.isOccupied != sb.isOccupied || sa.column != sb.column {
                return false
            }
        }
        return true
    }

    public func layer(id: Int64) -> LayerInfo? { layers.first { $0.id == id } }
    public func layerIndex(id: Int64) -> Int? { layers.first { $0.id == id }?.index }

    /// Highest column holding a clip in any layer (0 when the deck is empty).
    public var lastOccupiedColumn: Int {
        layers.flatMap { $0.slots }.filter(\.isOccupied).map(\.column).max() ?? 0
    }
}

public struct LayerInfo: Codable, Equatable, Sendable, Identifiable {
    public var index: Int          // 1-based
    public var id: Int64
    public var rawName: String     // "Layer #" = default, `#` shows the position
    public var nameParamID: Int64?
    public var slots: [SlotInfo]   // slots[i].column == i + 1

    public init(index: Int, id: Int64, rawName: String, nameParamID: Int64? = nil, slots: [SlotInfo]) {
        self.index = index; self.id = id; self.rawName = rawName; self.nameParamID = nameParamID; self.slots = slots
    }

    public var displayName: String { ArenaNames.display(rawName, index: index) }
    /// True when the user gave the layer a real name (not "Layer #" / "Layer N").
    public var hasCustomName: Bool { ArenaNames.isCustom(rawName, kind: "Layer", index: index) }

    public func slot(_ column: Int) -> SlotInfo? {
        guard column >= 1, column <= slots.count else { return nil }
        return slots[column - 1]
    }
}

public struct ColumnInfo: Codable, Equatable, Sendable {
    public var index: Int
    public var id: Int64
    public var rawName: String
    public var nameParamID: Int64?

    public init(index: Int, id: Int64, rawName: String, nameParamID: Int64? = nil) {
        self.index = index; self.id = id; self.rawName = rawName; self.nameParamID = nameParamID
    }

    public var displayName: String { ArenaNames.display(rawName, index: index) }
    public var hasCustomName: Bool { ArenaNames.isCustom(rawName, kind: "Column", index: index) }
}

public struct SlotInfo: Codable, Equatable, Sendable {
    public var column: Int
    public var clipID: Int64
    public var clipName: String?
    /// Clip `connected.value`: Empty / Disconnected / Previewing / Connected /
    /// Connected & previewing (Clip.connected options).
    public var state: String

    public init(column: Int, clipID: Int64, clipName: String?, state: String) {
        self.column = column; self.clipID = clipID; self.clipName = clipName; self.state = state
    }

    /// `Empty` is the only state meaning "nothing loaded". Offline clips with
    /// no video track still read `Disconnected` and count as occupied.
    public var isOccupied: Bool { state != "Empty" }
    public var isPlaying: Bool { state.hasPrefix("Connected") }
}

public enum ArenaNames {
    /// Arena stores the literal `#` and shows the position in its place.
    public static func display(_ raw: String, index: Int) -> String {
        raw.replacingOccurrences(of: "#", with: String(index))
    }

    public static func isCustom(_ raw: String, kind: String, index: Int) -> Bool {
        let shown = display(raw, index: index)
        return !(raw == "\(kind) #" || shown == "\(kind) \(index)" || raw.isEmpty)
    }
}
