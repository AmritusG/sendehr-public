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

/// One slot's result, verified by a REST GET after the open.
public struct SlotResult: Sendable {
    public var layerIndex: Int
    public var column: Int
    public var path: String
    public var error: ArenaError?
    /// The slot as Arena reports it after loading (the read-back).
    public var after: SlotInfo?

    public var ok: Bool { error == nil && (after?.isOccupied ?? false) }
}

public struct LoadOutcome: Sendable {
    public var plan: LoadPlan
    public var layerID: Int64?
    public var results: [SlotResult]
    public var triggered: Bool
    public var skipped: Int

    public var okCount: Int { results.filter(\.ok).count }

    public var summary: String {
        let where_ = "Layer \(plan.layerIndex)"
        var s = "Loaded \(okCount)/\(results.count) into \(where_)"
        if let first = results.first?.column, let last = results.last?.column {
            s += first == last ? ", column \(first)" : ", columns \(first)-\(last)"
        }
        if skipped > 0 { s += ", skipped \(skipped) occupied" }
        if triggered { s += ", triggered" }
        return s
    }
}

/// Fresh snapshot -> plan -> ask about occupied slots -> add layer/columns ->
/// open each file -> optional trigger -> verify each slot over REST.
public struct ArenaLoader: Sendable {
    public var client: ArenaClient
    public var remaps: [PathRemap]
    public var log: EventLog?

    public init(client: ArenaClient, remaps: [PathRemap] = [], log: EventLog? = nil) {
        self.client = client
        self.remaps = remaps
        self.log = log
    }

    /// - Parameters:
    ///   - paths: files in load order (see `MediaCollector`); non-media are dropped.
    ///   - replaceConfirmed: the user picked an explicit "Replace" item - no dialog.
    ///   - confirm: asked once when occupied slots would be overwritten.
    ///   - expectedLayers: new-layer picks: the indices the menu showed (logged if Arena's differ).
    public func load(paths: [String], to destination: Destination, trigger: Bool,
                     replaceConfirmed: Bool = false, expectedLayers: ClosedRange<Int>? = nil,
                     confirm: @Sendable ([Assignment]) async -> ConflictResolution) async throws -> LoadOutcome {
        let files = paths.filter { ArenaMediaTypes.isSupported(path: $0) }
        guard !files.isEmpty else { throw ArenaError.noFiles }

        var snap = try await client.snapshot()
        let fullPlan = try LoadPlanner.plan(files: files, to: destination, in: snap)
        var plan = fullPlan
        if !fullPlan.conflicts.isEmpty {
            let answer: ConflictResolution = replaceConfirmed ? .replace : await confirm(fullPlan.conflicts)
            log?.add("Occupied slots \(fullPlan.conflicts.map { "col \($0.column) \"\($0.replacing ?? "")\"" }.joined(separator: ", ")) -> \(answer.rawValue)")
            guard let resolved = fullPlan.resolving(answer) else { throw ArenaError.cancelled }
            plan = resolved
        }
        let skipped = fullPlan.assignments.count - plan.assignments.count

        var layerID = destination.layerID
        if plan.addLayer {
            try await client.addLayer()
            snap = try await client.snapshot()
            guard snap.layers.count == plan.layerIndex, let newLayer = snap.layers.last else {
                throw ArenaError.badResponse("new layer not found at index \(plan.layerIndex) (layers: \(snap.layers.count))")
            }
            layerID = newLayer.id
            log?.add("Added layer at top: index \(newLayer.index), id \(newLayer.id)")
            if let note = SendMenuModel.layerMismatch(expected: expectedLayers, actual: newLayer.index...newLayer.index) {
                log?.add(note)
            }
            if let name = destination.newLayerName {
                try await client.renameLayer(id: newLayer.id, name: name)
                log?.add("Named layer \(newLayer.index) \u{201C}\(name)\u{201D}")
            }
        } else if let id = layerID, snap.layerIndex(id: id) != plan.layerIndex {
            throw ArenaError.layerGone(layerID: id)
        }
        if plan.addColumns > 0 && !plan.assignments.isEmpty {
            let needed = (plan.assignments.map(\.column).max() ?? 0) - snap.columns.count
            for _ in 0..<max(0, needed) { try await client.addColumn() }
            if needed > 0 { log?.add("Added \(needed) column(s) at the end") }
        }

        let results = await open(plan.assignments, layer: plan.layerIndex)
        let triggered = trigger ? try await triggerFirst(results) : false
        return LoadOutcome(plan: plan, layerID: layerID, results: results, triggered: triggered, skipped: skipped)
    }

    /// Folders as New Layers: one fresh snapshot to plan, N empty-body layer
    /// adds (each at the top), one snapshot to confirm the N new
    /// layers and read their ids, then per layer (top-most = first folder):
    /// rename by id, open from column 1, verify each slot. With
    /// `trigger`, the first loaded clip of each new layer `scope` selects is
    /// triggered (all, or the top-most only).
    public func loadLayers(groups: [FolderGroup], trigger: Bool, scope: TriggerScope = .allNewLayers,
                           expectedLayers: ClosedRange<Int>? = nil) async throws -> LayersOutcome {
        var snap = try await client.snapshot()
        let plan = try LoadPlanner.planLayers(groups: groups, in: snap)
        for folder in plan.emptyFolders {
            log?.add("Folder \u{201C}\((folder as NSString).lastPathComponent)\u{201D} has no media file - no layer")
        }
        for _ in plan.layers { try await client.addLayer() }
        snap = try await client.snapshot()
        let expected = plan.baseLayerCount + plan.layers.count
        guard snap.layers.count == expected else {
            throw ArenaError.badResponse("expected \(expected) layers after adding \(plan.layers.count), found \(snap.layers.count)")
        }
        if let note = SendMenuModel.layerMismatch(expected: expectedLayers, actual: (plan.baseLayerCount + 1)...expected) {
            log?.add(note)
        }
        let neededColumns = (plan.layers.flatMap(\.assignments).map(\.column).max() ?? 0) - snap.columns.count
        for _ in 0..<max(0, neededColumns) { try await client.addColumn() }
        if neededColumns > 0 { log?.add("Added \(neededColumns) column(s) at the end") }

        var outcomes: [LoadOutcome] = []
        for (position, layer) in plan.layers.enumerated() {   // position 0 = top-most
            let info = snap.layers[layer.layerIndex - 1]
            try await client.renameLayer(id: info.id, name: layer.name)
            log?.add("Added layer \(layer.layerIndex) (id \(info.id)) \u{201C}\(layer.name)\u{201D}: \(layer.assignments.count) file(s)")
            let results = await open(layer.assignments, layer: layer.layerIndex)
            let triggered = trigger && scope.triggers(position: position) ? try await triggerFirst(results) : false
            let single = LoadPlan(layerIndex: layer.layerIndex, addLayer: true, addColumns: 0, assignments: layer.assignments)
            outcomes.append(LoadOutcome(plan: single, layerID: info.id, results: results, triggered: triggered, skipped: 0))
        }
        return LayersOutcome(plan: plan, layers: outcomes)
    }

    /// Opens each file into its slot and reads the slot back.
    func open(_ assignments: [Assignment], layer: Int) async -> [SlotResult] {
        var results: [SlotResult] = []
        for a in assignments {
            let arenaPath = remaps.remap(a.path)
            var r = SlotResult(layerIndex: layer, column: a.column, path: a.path)
            do {
                try await client.open(layer: layer, column: a.column, path: arenaPath)
                r.after = try await client.slot(layer: layer, column: a.column)
                log?.add("open L\(layer) C\(a.column) <- \(arenaPath) => \(r.after?.state ?? "?") \"\(r.after?.clipName ?? "")\"")
            } catch let e as ArenaError {
                r.error = e
                log?.add("open L\(layer) C\(a.column) <- \(arenaPath) FAILED: \(e.plainLine)")
            } catch {
                r.error = .badResponse(error.localizedDescription)
            }
            results.append(r)
        }
        return results
    }

    func triggerFirst(_ results: [SlotResult]) async throws -> Bool {
        guard let first = results.first(where: \.ok) else { return false }
        try await client.connect(layer: first.layerIndex, column: first.column)
        log?.add("Triggered L\(first.layerIndex) C\(first.column)")
        return true
    }
}

/// Result of Folders as New Layers: one `LoadOutcome` per new layer, top-most first.
public struct LayersOutcome: Sendable {
    public var plan: LayersPlan
    public var layers: [LoadOutcome]

    public var summary: String {
        let ok = layers.map(\.okCount).reduce(0, +), total = layers.map(\.results.count).reduce(0, +)
        let names = zip(plan.layers, layers).map { "\($0.layerIndex) \u{201C}\($0.name)\u{201D} \($1.okCount)/\($1.results.count)" }
        var s = "Loaded \(ok)/\(total) into \(layers.count) new layer\(layers.count == 1 ? "" : "s"), top first: " + names.joined(separator: ", ")
        if !plan.emptyFolders.isEmpty { s += "; \(plan.emptyFolders.count) empty folder(s), no layer" }
        if layers.contains(where: \.triggered) { s += ", triggered" }
        return s
    }
}
