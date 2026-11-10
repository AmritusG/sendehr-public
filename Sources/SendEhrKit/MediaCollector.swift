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

/// Sort keys for the order files fill consecutive columns. Values come from
/// URL resource keys (Apple: URLResourceKey .contentModificationDateKey,
/// .creationDateKey, .addedToDirectoryDateKey, .fileSizeKey); names compare
/// Finder-style with `localizedStandardCompare` ("clip 2" before "clip 10").
public enum SortKey: String, Codable, CaseIterable, Sendable {
    case name, dateModified, dateCreated, dateAdded, size, kind

    public var title: String {
        switch self {
        case .name: return "Name"
        case .dateModified: return "Date Modified"
        case .dateCreated: return "Date Created"
        case .dateAdded: return "Date Added"
        case .size: return "Size"
        case .kind: return "Kind"
        }
    }
}

/// The attributes a sort needs, read once per item.
public struct MediaItem: Equatable, Sendable {
    public var path: String
    public var isFolder: Bool
    public var modified: Date?
    public var created: Date?
    public var added: Date?
    public var size: Int?

    public init(path: String, isFolder: Bool = false, modified: Date? = nil, created: Date? = nil,
                added: Date? = nil, size: Int? = nil) {
        self.path = path; self.isFolder = isFolder; self.modified = modified
        self.created = created; self.added = added; self.size = size
    }

    public var name: String { (path as NSString).lastPathComponent }
    /// Kind = the file extension (Arena's types are all identified by it).
    public var kind: String { isFolder ? "" : (path as NSString).pathExtension.lowercased() }

    static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
        .contentModificationDateKey, .creationDateKey, .addedToDirectoryDateKey, .fileSizeKey,
    ]

    init(url: URL, values v: URLResourceValues?) {
        self.init(path: url.path, isFolder: (v?.isDirectory ?? false) && !(v?.isPackage ?? false),
                  modified: v?.contentModificationDate, created: v?.creationDate,
                  added: v?.addedToDirectoryDate, size: v?.fileSize)
    }
}

public enum MediaSorter {
    /// Ascending/descending by `key`; ties (and missing values, which sort as
    /// the smallest) fall back to the natural name order, then the full path.
    public static func sort(_ items: [MediaItem], by key: SortKey, ascending: Bool) -> [MediaItem] {
        items.sorted { a, b in
            let primary = compare(a, b, key)
            if primary != .orderedSame { return ascending ? primary == .orderedAscending : primary == .orderedDescending }
            let byName = a.name.localizedStandardCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.path < b.path
        }
    }

    static func compare(_ a: MediaItem, _ b: MediaItem, _ key: SortKey) -> ComparisonResult {
        func cmp<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult { x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame) }
        switch key {
        case .name: return a.name.localizedStandardCompare(b.name)
        case .dateModified: return cmp(a.modified ?? .distantPast, b.modified ?? .distantPast)
        case .dateCreated: return cmp(a.created ?? .distantPast, b.created ?? .distantPast)
        case .dateAdded: return cmp(a.added ?? .distantPast, b.added ?? .distantPast)
        case .size: return cmp(a.size ?? -1, b.size ?? -1)
        case .kind: return a.kind.localizedStandardCompare(b.kind)
        }
    }
}

/// The ordered media files a selection (files and/or folders) expands to.
public struct MediaCollection: Equatable, Sendable {
    public var files: [String]
    /// Selected folders (top level), in sort order.
    public var folders: [String]
    /// Each selected folder with the files it expanded to (subfolders included
    /// in their parent), in sort order.
    public var groups: [FolderGroup] = []
    /// Files that came out of folders (the large-folder ask counts these).
    public var fromFolders: Int
    public var skippedHidden: Int
    public var skippedNonMedia: Int
    /// Subfolders left out because Include Subfolders is off.
    public var subfoldersNotIncluded: Int = 0

    /// Selected files outside any selected folder.
    public var looseFiles: Int { files.count - fromFolders }

    /// Ask once before loading: folders expanded to more files than `threshold`.
    /// `foldersOnly` (Folders as New Layers) counts the folders' files only.
    public func needsConfirmation(threshold: Int, foldersOnly: Bool = false) -> Bool {
        !folders.isEmpty && (foldersOnly ? fromFolders : files.count) > threshold
    }

    public var summary: String {
        var s = "\(files.count) file\(files.count == 1 ? "" : "s")"
        if !folders.isEmpty { s += " (\(fromFolders) from \(folders.count) folder\(folders.count == 1 ? "" : "s"))" }
        var skipped: [String] = []
        if skippedHidden > 0 { skipped.append("\(skippedHidden) hidden") }
        if skippedNonMedia > 0 { skipped.append("\(skippedNonMedia) not a type Arena opens") }
        if subfoldersNotIncluded > 0 { skipped.append("\(subfoldersNotIncluded) subfolder\(subfoldersNotIncluded == 1 ? "" : "s") (Include Subfolders is off)") }
        if !skipped.isEmpty { s += ", skipped " + skipped.joined(separator: ", ") }
        return s
    }
}

/// A selected folder and the media files it expanded to.
public struct FolderGroup: Equatable, Sendable {
    public var folder: String
    public var files: [String]
    public init(folder: String, files: [String]) { self.folder = folder; self.files = files }
    /// The layer name: the folder's name.
    public var name: String { (folder as NSString).lastPathComponent }
}

/// Expands a selection into the media files Arena accepts, in sort order.
/// The selected items are ordered by the sort setting; each folder expands in
/// place: its own files (sorted), then - with Include Subfolders - each
/// subfolder (sorted) the same way. Hidden items inside folders and anything
/// that is not a type Arena opens are skipped and counted; packages (.app,
/// bundles) count as non-media; symlinked folders are not followed.
/// Runs in the host (not sandboxed): the Finder extension may read metadata of
/// a selected folder but not list it (EPERM).
public enum MediaCollector {
    public static func collect(paths: [String], includeSubfolders: Bool, sortKey: SortKey, ascending: Bool,
                               fileManager: FileManager = .default) -> MediaCollection {
        var out = MediaCollection(files: [], folders: [], fromFolders: 0, skippedHidden: 0, skippedNonMedia: 0)
        let top = paths.map { p -> MediaItem in
            let url = URL(fileURLWithPath: p)
            return MediaItem(url: url, values: try? url.resourceValues(forKeys: MediaItem.keys))
        }
        for item in MediaSorter.sort(top, by: sortKey, ascending: ascending) {
            if item.isFolder {
                out.folders.append(item.path)
                let before = out.files.count
                expand(item.path, recursive: includeSubfolders, sortKey: sortKey, ascending: ascending, fm: fileManager, into: &out)
                out.fromFolders += out.files.count - before
                out.groups.append(FolderGroup(folder: item.path, files: Array(out.files[before...])))
            } else if ArenaMediaTypes.isSupported(path: item.path) {
                out.files.append(item.path)
            } else {
                out.skippedNonMedia += 1
            }
        }
        return out
    }

    private static func expand(_ folder: String, recursive: Bool, sortKey: SortKey, ascending: Bool,
                               fm: FileManager, into out: inout MediaCollection) {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        guard let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(MediaItem.keys), options: []) else { return }
        var files: [MediaItem] = [], subfolders: [MediaItem] = []
        for child in children {
            let v = try? child.resourceValues(forKeys: MediaItem.keys)
            if v?.isHidden == true || child.lastPathComponent.hasPrefix(".") { out.skippedHidden += 1; continue }
            if v?.isSymbolicLink == true {
                // Follow links to files only (a linked folder could loop).
                let target = child.resolvingSymlinksInPath()
                let tv = try? target.resourceValues(forKeys: MediaItem.keys)
                if tv?.isDirectory == true { continue }
                if ArenaMediaTypes.isSupported(path: child.path) { files.append(MediaItem(url: child, values: tv)) }
                else { out.skippedNonMedia += 1 }
                continue
            }
            let item = MediaItem(url: child, values: v)
            if item.isFolder {
                if recursive { subfolders.append(item) } else { out.subfoldersNotIncluded += 1 }
            } else if ArenaMediaTypes.isSupported(path: item.path) {
                files.append(item)
            } else {
                out.skippedNonMedia += 1
            }
        }
        out.files += MediaSorter.sort(files, by: sortKey, ascending: ascending).map(\.path)
        for sub in MediaSorter.sort(subfolders, by: sortKey, ascending: ascending) {
            expand(sub.path, recursive: true, sortKey: sortKey, ascending: ascending, fm: fm, into: &out)
        }
    }
}

/// A menu selection split into media files, folders and the rest. Folders are
/// told apart by URL metadata only (`hasDirectoryPath` / isDirectory, not
/// packages): readable from the sandboxed Finder extension.
public struct MediaSelection: Sendable {
    public var files: [URL] = []
    public var folders: [URL] = []
    public var unsupported = 0

    public init(_ urls: [URL]) {
        for u in urls {
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isDir = v?.isDirectory ?? u.hasDirectoryPath
            if isDir && !(v?.isPackage ?? false) { folders.append(u) }
            else if ArenaMediaTypes.isSupported(u) { files.append(u) }
            else { unsupported += 1 }
        }
    }
}
