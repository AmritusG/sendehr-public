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

/// One-time carry-over of the settings written under the app's former name,
/// SyncEhr (until 1.0.2). The old names below are the only place they remain.
/// Rule: when the old folder has settings.json and the new one does not, copy
/// settings.json and recents.json across with their dates and permissions
/// (cp -p). The old files are left in place.
public enum LegacyMigration {
    public static let files = ["settings.json", "recents.json"]
    /// App Group of SyncEhr.app and its Finder extension; the host app lists it
    /// in its entitlements so it can read the old container without a prompt.
    public static let legacyAppGroup = "3A3L2C6DFB.com.amritus.syncehr"
    static let legacyAppGroupFolder = "SyncEhr"
    static let legacyKitFolder = "SyncEhrKit"

    /// Old and new kit folders under Application Support for a host bundle id.
    public static func kitFolders(applicationSupport: URL, bundleID: String) -> (old: URL, new: URL) {
        (applicationSupport.appendingPathComponent(legacyKitFolder, isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true),
         applicationSupport.appendingPathComponent(SharedStore.kitFolder, isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true))
    }

    /// Old and new App Group folders under `home` (layout of ~/Library/Group Containers).
    public static func appGroupFolders(home: URL, newContainer: URL) -> (old: URL, new: URL) {
        (home.appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(legacyAppGroup, isDirectory: true)
            .appendingPathComponent(legacyAppGroupFolder, isDirectory: true),
         newContainer.appendingPathComponent(SharedStore.appGroupFolder, isDirectory: true))
    }

    /// App Group path: `container` is `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`.
    /// The old container is looked up only when its settings file exists (a stat
    /// is allowed): the lookup creates a missing container, and it is what grants
    /// access to an existing one; a plain path read is denied by the system's
    /// app data protection (macOS 27: EPERM, no prompt).
    public static func migrateAppGroup(home: URL, container: (String) -> URL?) -> String? {
        guard let newContainer = container(SharedStore.appGroup) else { return nil }
        let dirs = appGroupFolders(home: home, newContainer: newContainer)
        guard FileManager.default.fileExists(atPath: dirs.old.appendingPathComponent("settings.json").path),
              !FileManager.default.fileExists(atPath: dirs.new.appendingPathComponent("settings.json").path) else { return nil }
        guard container(legacyAppGroup) != nil else { return "Settings migration: no access to \(legacyAppGroup)" }
        return migrate(from: dirs.old, to: dirs.new)
    }

    /// Returns a log line when something was copied (or failed), nil when there was nothing to do.
    @discardableResult
    public static func migrate(from old: URL, to new: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.appendingPathComponent("settings.json").path),
              !fm.fileExists(atPath: new.appendingPathComponent("settings.json").path) else { return nil }
        var copied: [String] = []
        do {
            try fm.createDirectory(at: new, withIntermediateDirectories: true)
            for name in files {
                let src = old.appendingPathComponent(name), dst = new.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
                try fm.copyItem(at: src, to: dst)
                // copyItem keeps the contents; set dates and mode explicitly so the copy matches cp -p.
                let a = try fm.attributesOfItem(atPath: src.path)
                try fm.setAttributes([.modificationDate: a[.modificationDate] as Any,
                                      .posixPermissions: a[.posixPermissions] as Any], ofItemAtPath: dst.path)
                copied.append(name)
            }
        } catch {
            return "Settings migration from \(old.path) failed after \(copied): \(error)"
        }
        return "Settings migrated from \(old.path): \(copied.joined(separator: ", "))"
    }
}
