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

/// What a menu item does when picked.
public enum MenuAction: Hashable, Codable, Sendable {
    case load(Destination, replace: Bool)
    /// Launch / show the SendEhr host app (Finder extension only).
    case openHost
    /// Change a shared setting (Sort By, Include Subfolders, Trigger After Load, Arena Updates).
    case setting(SettingChange)
    /// Fetch the composition now (On Demand / Interval modes).
    case refresh
}

/// A platform-neutral menu tree. `SendEhrKitUI` renders it as an NSMenu
/// (Finder Sync) or a SwiftUI menu (MaCrate); both show identical items.
public indirect enum MenuNode: Equatable, Sendable {
    case action(title: String, action: MenuAction, label: String)
    case submenu(title: String, children: [MenuNode])
    /// An item with a checkmark showing its current state.
    case toggle(title: String, isOn: Bool, action: MenuAction)
    /// A disabled line that explains something.
    case info(String)
    case separator

    public var title: String? {
        switch self {
        case let .action(t, _, _), let .submenu(t, _), let .toggle(t, _, _): return t
        case let .info(t): return t
        case .separator: return nil
        }
    }
}

public struct SendMenuInput: Sendable {
    public var snapshot: CompositionSnapshot?
    public var status: ArenaStatus
    public var hostAlive: Bool
    public var recents: [RecentTarget]
    public var settings: SendEhrSettings
    /// Media files selected directly.
    public var fileCount: Int
    public var unsupportedCount: Int
    /// Selected folders: they expand when loading, so their file count is not
    /// known while the menu is built (the Finder extension cannot list them).
    public var folderNames: [String]
    /// When the composition last arrived (On Demand / Interval show "Updated n s ago").
    public var updatedAt: Date?
    public var now: Date

    public init(snapshot: CompositionSnapshot?, status: ArenaStatus, hostAlive: Bool = true,
                recents: [RecentTarget] = [], settings: SendEhrSettings = .default,
                fileCount: Int, unsupportedCount: Int = 0, folderNames: [String] = [],
                updatedAt: Date? = nil, now: Date = Date()) {
        self.snapshot = snapshot; self.status = status; self.hostAlive = hostAlive; self.recents = recents
        self.settings = settings; self.fileCount = fileCount; self.unsupportedCount = unsupportedCount
        self.folderNames = folderNames; self.updatedAt = updatedAt; self.now = now
    }

    /// File count when it is known (no folders), else nil.
    public var knownCount: Int? { folderNames.isEmpty ? fileCount : nil }
    public var hasItems: Bool { fileCount > 0 || !folderNames.isEmpty }
}

public enum SendMenuModel {
    public static let rootTitle = "Send to Arena"
    static let chunk = 50

    /// The children of the "Send to Arena" submenu. Never empty: when Arena
    /// can't be used it is one disabled line saying why.
    public static func build(_ input: SendMenuInput) -> [MenuNode] {
        guard input.hostAlive else {
            return [.info("SendEhr is not running"), .action(title: "Open SendEhr", action: .openHost, label: "Open SendEhr")]
        }
        guard input.hasItems else { return [.info(ArenaError.noFiles.plainLine)] }
        guard input.status.isConnected, let snap = input.snapshot else {
            let line: String
            if case .unknown = input.status { line = "Connecting to Arena..." } else { line = input.status.plainLine }
            return [.info(line)] + freshnessNodes(input)
        }

        var items: [MenuNode] = []
        let known = input.knownCount
        let n = known ?? max(input.fileCount, 2)   // folders: plural wording, ranges hidden
        let folders = input.folderNames.count
        let sortNote = "sorted by \(input.settings.sortDescription)"
        if folders > 0 {
            var what = folders == 1 ? "Folder \u{201C}\(input.folderNames[0])\u{201D}" : "\(folders) folders"
            if input.fileCount > 0 { what += " + \(input.fileCount) file\(input.fileCount == 1 ? "" : "s")" }
            items.append(.info("\(what) -> consecutive columns, \(sortNote)"))
        } else if n > 1 {
            items.append(.info("\(n) files -> consecutive columns from your pick, \(sortNote)"))
        }
        if input.unsupportedCount > 0 {
            items.append(.info("\(input.unsupportedCount) skipped (not a type Arena opens)"))
        }

        let recent = input.recents.compactMap { recentNode($0, snap: snap, settings: input.settings, fileCount: n) }
        if !recent.isEmpty {
            items.append(.info("Recent"))
            items += recent
            items.append(.separator)
        } else if !items.isEmpty {
            items.append(.separator)
        }

        let newIndex = snap.layers.count + 1
        items.append(.action(title: "New Layer at Top (Layer \(newIndex))", action: .load(.newLayer, replace: false),
                             label: "New Layer"))
        if folders == 1 {
            let name = input.folderNames[0]
            let dest = Destination.newNamedLayer(name: name)
            let label = "Folder as New Layer \u{201C}\(name)\u{201D}"
            items.append(.action(title: label + layersSuffix(dest, snap: snap, folderCount: 1),
                                 action: .load(dest, replace: false), label: label))
        } else if folders > 1 {
            let label = "Folders as New Layers (\(folders))"
            items.append(.action(title: label + layersSuffix(.layerPerFolder, snap: snap, folderCount: folders),
                                 action: .load(.layerPerFolder, replace: false), label: label))
        }
        items.append(.separator)

        for layer in snap.layers.reversed() {   // Arena shows the highest layer on top
            items.append(.submenu(title: layerTitle(layer), children: layerChildren(layer, snap: snap, settings: input.settings,
                                                                                   fileCount: n, rangesKnown: known != nil)))
        }
        items.append(.separator)
        items += settingNodes(input.settings, folders: folders > 0, triggerScope: folders > 1)
        items.append(.separator)
        let deck = snap.deckName.isEmpty ? "" : "Deck \u{201C}\(snap.deckName)\u{201D} \u{00B7} "
        items.append(.info(deck + snap.compositionName))
        items += freshnessNodes(input)
        return items
    }

    /// On Demand / Interval: "Updated n s ago" + Refresh (the labels can be one
    /// fetch behind; a load always re-reads a fresh composition). Nothing in Live.
    public static func freshnessNodes(_ input: SendMenuInput) -> [MenuNode] {
        guard input.settings.updateMode != .live else { return [] }
        return [.info(updatedText(input.updatedAt, now: input.now)), .action(title: "Refresh", action: .refresh, label: "Refresh")]
    }

    /// "Updated just now", "Updated 12 s ago", "Updated 3 min ago", "Not updated yet".
    public static func updatedText(_ updatedAt: Date?, now: Date) -> String {
        guard let updatedAt else { return "Not updated yet" }
        let s = max(0, Int(now.timeIntervalSince(updatedAt)))
        if s < 1 { return "Updated just now" }
        if s < 120 { return "Updated \(s) s ago" }
        if s < 7200 { return "Updated \(s / 60) min ago" }
        return "Updated \(s / 3600) h ago"
    }

    /// Menu bar form: "Arena Updates: Live / On Demand / Interval (1 min)" checkmarked,
    /// then "Interval (1 min)" submenu with the choices.
    public static func inlineUpdateNodes(_ s: SendEhrSettings) -> [MenuNode] {
        guard case let .submenu(_, children) = updateNodes(s) else { return [] }
        let modes = children.prefix(3).map { node -> MenuNode in
            guard case let .toggle(t, on, a) = node else { return node }
            return .toggle(title: "Arena Updates: \(t)", isOn: on, action: a)
        }
        return [.separator] + modes + [.submenu(title: "Interval (\(ArenaUpdateMode.intervalTitle(s.updateInterval)))",
                                                children: Array(children.dropFirst(4)))]
    }

    /// The "Arena Updates (Live)" submenu: the three modes, then the interval choices.
    public static func updateNodes(_ s: SendEhrSettings) -> MenuNode {
        var children: [MenuNode] = ArenaUpdateMode.allCases.map {
            .toggle(title: $0 == .interval ? "Interval (\(ArenaUpdateMode.intervalTitle(s.updateInterval)))" : $0.title,
                    isOn: s.updateMode == $0, action: .setting(.updateMode($0)))
        }
        children.append(.separator)
        children += ArenaUpdateMode.intervals.map {
            .toggle(title: "Every \(ArenaUpdateMode.intervalTitle($0))", isOn: s.updateMode == .interval && s.updateInterval == $0,
                    action: .setting(.updateInterval($0)))
        }
        return .submenu(title: "Arena Updates (\(s.updateDescription))", children: children)
    }

    /// The layer indices a new-layer pick will create, read from `snap` (the
    /// cache at menu time): one layer above the current top, or one per folder
    /// for Folders as New Layers. The load re-reads a fresh snapshot and logs
    /// when Arena's real indices differ (`layerMismatch`). Empty folders make
    /// no layer, which the menu cannot know (the extension can't list folders).
    public static func expectedLayers(_ destination: Destination, snap: CompositionSnapshot?, folderCount: Int) -> ClosedRange<Int>? {
        guard let snap else { return nil }
        let base = snap.layers.count
        switch destination {
        case .newLayer, .newNamedLayer: return (base + 1)...(base + 1)
        case .layerPerFolder: return folderCount > 0 ? (base + 1)...(base + folderCount) : nil
        case .slot, .nextFree, .appendColumns: return nil
        }
    }

    /// "Layer 24" or "Layers 24\u{2013}26".
    public static func layersText(_ r: ClosedRange<Int>) -> String {
        r.count == 1 ? "Layer \(r.lowerBound)" : "Layers \(r.lowerBound)\u{2013}\(r.upperBound)"
    }

    static func layersSuffix(_ destination: Destination, snap: CompositionSnapshot, folderCount: Int) -> String {
        expectedLayers(destination, snap: snap, folderCount: folderCount).map { " - " + layersText($0) } ?? ""
    }

    /// The log line when the layers Arena made differ from what the menu showed, else nil.
    public static func layerMismatch(expected: ClosedRange<Int>?, actual: ClosedRange<Int>) -> String? {
        guard let expected, expected != actual else { return nil }
        return "Menu showed \(layersText(expected)) (cache at menu time); Arena made \(layersText(actual))"
    }

    public static func layerTitle(_ layer: LayerInfo) -> String {
        layer.hasCustomName ? "Layer \(layer.index) \u{201C}\(layer.displayName)\u{201D}" : "Layer \(layer.index)"
    }

    public static func columnTitle(_ column: Int, snap: CompositionSnapshot) -> String {
        guard column <= snap.columns.count else { return "Column \(column)" }
        let info = snap.columns[column - 1]
        return info.hasCustomName ? "Column \(column) \u{201C}\(info.displayName)\u{201D}" : "Column \(column)"
    }

    static func slotSuffix(_ slot: SlotInfo?) -> String {
        guard let slot, slot.isOccupied else { return "(empty)" }
        let name = slot.clipName ?? "(unnamed clip)"
        return (slot.isPlaying ? "\u{25B6} " : "\u{25CF} ") + name
    }

    static func freeColumns(_ layer: LayerInfo, snap: CompositionSnapshot, count: Int) -> [Int] {
        (try? LoadPlanner.plan(files: Array(repeating: "x.mov", count: count), to: .nextFree(layerID: layer.id), in: snap))?
            .assignments.map(\.column) ?? []
    }

    static func range(_ cols: [Int]) -> String {
        guard let f = cols.first, let l = cols.last else { return "" }
        if cols.count == 1 { return "\(f)" }
        if l - f + 1 == cols.count { return "\(f)\u{2013}\(l)" }
        return cols.map(String.init).joined(separator: ", ")
    }

    /// Sort By (one shared setting), Include Subfolders (folders only), Trigger
    /// After Load, the Trigger Scope pair (only where several new layers
    /// can be made: 2+ folders in Finder, always in the menu bar), Arena Updates.
    /// `updatesInline`: the menu bar shows the three modes as top-level checkmarked
    /// items (+ an "Interval" submenu) instead of the "Arena Updates (…)" submenu.
    public static func settingNodes(_ s: SendEhrSettings, folders: Bool, triggerScope: Bool,
                                    updatesInline: Bool = false) -> [MenuNode] {
        var sort: [MenuNode] = SortKey.allCases.map {
            .toggle(title: $0.title, isOn: s.sortKey == $0, action: .setting(.sortKey($0)))
        }
        sort.append(.separator)
        sort.append(.toggle(title: "Ascending", isOn: s.sortAscending, action: .setting(.sortAscending(true))))
        sort.append(.toggle(title: "Descending", isOn: !s.sortAscending, action: .setting(.sortAscending(false))))
        var out: [MenuNode] = [.submenu(title: "Sort By (\(s.sortDescription))", children: sort)]
        if folders {
            out.append(.toggle(title: "Include Subfolders", isOn: s.includeSubfolders,
                               action: .setting(.includeSubfolders(!s.includeSubfolders))))
        }
        out.append(.toggle(title: "Trigger After Load", isOn: s.triggerAfterLoad,
                           action: .setting(.triggerAfterLoad(!s.triggerAfterLoad))))
        if triggerScope {
            out += TriggerScope.allCases.map {
                .toggle(title: "Trigger: \($0.title)", isOn: s.triggerScope == $0, action: .setting(.triggerScope($0)))
            }
        }
        out += updatesInline ? inlineUpdateNodes(s) : [updateNodes(s)]
        return out
    }

    static func layerChildren(_ layer: LayerInfo, snap: CompositionSnapshot, settings: SendEhrSettings, fileCount n: Int,
                              rangesKnown: Bool = true) -> [MenuNode] {
        var out: [MenuNode] = []
        let free = freeColumns(layer, snap: snap, count: n)
        out.append(.action(title: "Next Free Column\(n > 1 ? "s" : "")" + (rangesKnown ? " (\(range(free)))" : ""),
                           action: .load(.nextFree(layerID: layer.id), replace: false),
                           label: "\(layerTitle(layer)) \u{203A} Next Free Column"))
        let total = snap.columns.count
        let appended = Array((total + 1)...(total + n))
        out.append(.action(title: "Append as New Column\(n > 1 ? "s" : "")" + (rangesKnown ? " (\(range(appended)))" : ""),
                           action: .load(.appendColumns(layerID: layer.id), replace: false),
                           label: "\(layerTitle(layer)) \u{203A} Append as New Column"))
        out.append(.separator)

        let layerLast = layer.slots.filter(\.isOccupied).map(\.column).max() ?? 0
        let shown = min(total, max(snap.lastOccupiedColumn, layerLast) + settings.extraEmptyColumns)
        for c in stride(from: 1, through: max(shown, min(total, 1)), by: 1) {
            out.append(columnNode(layer, column: c, snap: snap, settings: settings))
        }
        if shown < total {
            var start = shown + 1
            var chunks: [MenuNode] = []
            while start <= total {
                let end = min(total, start + chunk - 1)
                chunks.append(.submenu(title: "Columns \(start)\u{2013}\(end)",
                                       children: (start...end).map { columnNode(layer, column: $0, snap: snap, settings: settings) }))
                start = end + 1
            }
            out.append(chunks.count == 1 ? chunks[0] : .submenu(title: "More Columns (\(shown + 1)\u{2013}\(total))", children: chunks))
        }
        return out
    }

    static func columnNode(_ layer: LayerInfo, column c: Int, snap: CompositionSnapshot, settings: SendEhrSettings) -> MenuNode {
        let slot = layer.slot(c)
        let title = "\(columnTitle(c, snap: snap)) \u{00B7} \(slotSuffix(slot))"
        let label = "\(layerTitle(layer)) \u{203A} \(columnTitle(c, snap: snap))"
        let dest = Destination.slot(layerID: layer.id, column: c)
        if settings.occupiedSlotMode == .replaceItem, let slot, slot.isOccupied {
            return .submenu(title: title, children: [
                .action(title: "Replace \u{201C}\(slot.clipName ?? "clip")\u{201D}", action: .load(dest, replace: true), label: label),
            ])
        }
        return .action(title: title, action: .load(dest, replace: false), label: label)
    }

    static func recentNode(_ r: RecentTarget, snap: CompositionSnapshot, settings: SendEhrSettings, fileCount: Int) -> MenuNode? {
        guard let id = r.destination.layerID, let layer = snap.layer(id: id) else { return nil }
        switch r.destination {
        case let .slot(_, column):
            guard column <= snap.columns.count else { return nil }
            let slot = layer.slot(column)
            let title = "\(layerTitle(layer)) \u{203A} \(columnTitle(column, snap: snap)) \u{00B7} \(slotSuffix(slot))"
            if settings.occupiedSlotMode == .replaceItem, let slot, slot.isOccupied {
                return .submenu(title: title, children: [
                    .action(title: "Replace \u{201C}\(slot.clipName ?? "clip")\u{201D}", action: .load(r.destination, replace: true), label: r.label),
                ])
            }
            return .action(title: title, action: .load(r.destination, replace: false), label: r.label)
        case .nextFree:
            return .action(title: "\(layerTitle(layer)) \u{203A} Next Free Column", action: .load(r.destination, replace: false), label: r.label)
        case .appendColumns:
            return .action(title: "\(layerTitle(layer)) \u{203A} Append as New Column", action: .load(r.destination, replace: false), label: r.label)
        case .newLayer, .newNamedLayer, .layerPerFolder:
            return nil
        }
    }
}
