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

/// Where a selection of files should go. Layers are addressed by Arena's
/// stable layer id and resolved to an index against a fresh
/// snapshot right before loading, so a reordered comp never hits the wrong layer.
public enum Destination: Codable, Hashable, Sendable {
    /// Fill consecutive columns starting at `column` (1-based).
    case slot(layerID: Int64, column: Int)
    /// Each file into the next empty slot of the layer, left to right.
    case nextFree(layerID: Int64)
    /// Add one new column per file at the end of the deck, load there.
    case appendColumns(layerID: Int64)
    /// Add a layer at the top (end of the list) and load from column 1.
    case newLayer
    /// Same as `newLayer`, then the layer is renamed (Folder as New Layer).
    case newNamedLayer(name: String)
    /// Several folders: one new layer per folder, named after it, files from
    /// column 1; the first folder in Sort By order is the top-most new layer.
    /// Loose files in the selection are ignored.
    case layerPerFolder

    public var layerID: Int64? {
        switch self {
        case let .slot(id, _), let .nextFree(id), let .appendColumns(id): return id
        case .newLayer, .newNamedLayer, .layerPerFolder: return nil
        }
    }

    /// The name a new layer gets, if any.
    public var newLayerName: String? {
        if case let .newNamedLayer(name) = self { return name }
        return nil
    }
}

/// What to do with a file whose target slot already holds a clip.
public enum ConflictResolution: String, Codable, Sendable {
    case replace, skip, cancel
}

public struct Assignment: Equatable, Sendable {
    public var column: Int
    public var path: String
    /// The clip name currently in the slot, when occupied.
    public var replacing: String?
}

/// A fully resolved, side-effect-free plan: what to add, and which file goes where.
public struct LoadPlan: Equatable, Sendable {
    /// Layer index the files land on (after `addLayer`, if any).
    public var layerIndex: Int
    public var addLayer: Bool
    /// Columns to append at the end of the deck before loading.
    public var addColumns: Int
    public var assignments: [Assignment]

    public var conflicts: [Assignment] { assignments.filter { $0.replacing != nil } }

    /// Applies the user's answer for occupied slots.
    public func resolving(_ resolution: ConflictResolution) -> LoadPlan? {
        switch resolution {
        case .replace: return self
        case .cancel: return nil
        case .skip:
            var p = self
            p.assignments = assignments.filter { $0.replacing == nil }
            return p
        }
    }
}

public enum LoadPlanner {
    public static func plan(files: [String], to destination: Destination, in snap: CompositionSnapshot) throws -> LoadPlan {
        guard !files.isEmpty else { throw ArenaError.noFiles }
        let totalColumns = snap.columns.count

        switch destination {
        case .layerPerFolder:
            throw ArenaError.badResponse("one layer per folder is planned with planLayers")
        case .newLayer, .newNamedLayer:
            let layerIndex = snap.layers.count + 1
            let assignments = files.enumerated().map { Assignment(column: $0.offset + 1, path: $0.element, replacing: nil) }
            return LoadPlan(layerIndex: layerIndex, addLayer: true,
                            addColumns: max(0, files.count - totalColumns), assignments: assignments)

        case let .appendColumns(layerID):
            guard let layer = snap.layer(id: layerID) else { throw ArenaError.layerGone(layerID: layerID) }
            let assignments = files.enumerated().map {
                Assignment(column: totalColumns + $0.offset + 1, path: $0.element, replacing: nil)
            }
            return LoadPlan(layerIndex: layer.index, addLayer: false, addColumns: files.count, assignments: assignments)

        case let .nextFree(layerID):
            guard let layer = snap.layer(id: layerID) else { throw ArenaError.layerGone(layerID: layerID) }
            var free = (1...max(totalColumns, 1)).filter { c in
                c <= totalColumns && !(layer.slot(c)?.isOccupied ?? false)
            }
            var added = 0
            while free.count < files.count {
                added += 1
                free.append(totalColumns + added)
            }
            let assignments = zip(files, free).map { Assignment(column: $0.1, path: $0.0, replacing: nil) }
            return LoadPlan(layerIndex: layer.index, addLayer: false, addColumns: added, assignments: assignments)

        case let .slot(layerID, column):
            guard let layer = snap.layer(id: layerID) else { throw ArenaError.layerGone(layerID: layerID) }
            let start = max(1, column)
            let assignments = files.enumerated().map { (i, path) -> Assignment in
                let c = start + i
                let slot = layer.slot(c)
                let replacing = (slot?.isOccupied ?? false) ? (slot?.clipName ?? "(unnamed clip)") : nil
                return Assignment(column: c, path: path, replacing: replacing)
            }
            let lastColumn = start + files.count - 1
            return LoadPlan(layerIndex: layer.index, addLayer: false,
                            addColumns: max(0, lastColumn - totalColumns), assignments: assignments)
        }
    }

    /// One new layer per non-empty folder. All layers are added with an
    /// empty-body `POST /composition/layers/add` ("added at the end"),
    /// the end being the top in Arena, so they take indexes base+1...base+N;
    /// folder k (0-based, in Sort By order) is given index base+N-k: the first
    /// folder ends top-most and the stack reads top-down like the menu.
    public static func planLayers(groups: [FolderGroup], in snap: CompositionSnapshot) throws -> LayersPlan {
        let filled = groups.filter { !$0.files.isEmpty }
        guard !filled.isEmpty else { throw ArenaError.noFiles }
        let base = snap.layers.count
        let layers = filled.enumerated().map { k, g in
            LayerPlan(name: g.name, folder: g.folder, layerIndex: base + filled.count - k,
                      assignments: g.files.enumerated().map { Assignment(column: $0.offset + 1, path: $0.element, replacing: nil) })
        }
        let widest = filled.map(\.files.count).max() ?? 0
        return LayersPlan(baseLayerCount: base, layers: layers, addColumns: max(0, widest - snap.columns.count),
                          emptyFolders: groups.filter { $0.files.isEmpty }.map(\.folder))
    }
}

/// One new layer of a `LayersPlan`.
public struct LayerPlan: Equatable, Sendable {
    public var name: String
    public var folder: String
    /// Index after all of the plan's layers are added.
    public var layerIndex: Int
    public var assignments: [Assignment]
}

/// Folders as New Layers: what to add and which file goes where.
public struct LayersPlan: Equatable, Sendable {
    /// Layers in the comp before adding.
    public var baseLayerCount: Int
    /// In Sort By order (first = top-most = highest index).
    public var layers: [LayerPlan]
    /// Columns to append (columns are composition-wide).
    public var addColumns: Int
    /// Folders that expanded to no media file: no layer.
    public var emptyFolders: [String]
}
