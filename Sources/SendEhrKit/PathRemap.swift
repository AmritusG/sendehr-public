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

/// Maps a path on this Mac to the same file as the Arena machine sees it.
/// Needed when Arena runs on another computer: `/Volumes/X/clip.mov` here may
/// be `/Volumes/Y/clip.mov` there. Prefixes match whole path components only.
public struct PathRemap: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var localPrefix: String
    public var remotePrefix: String

    public init(id: UUID = UUID(), localPrefix: String, remotePrefix: String) {
        self.id = id
        self.localPrefix = localPrefix
        self.remotePrefix = remotePrefix
    }

    static func trimmed(_ prefix: String) -> String {
        var p = prefix
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// The remapped path, or nil when `path` is not under `localPrefix`.
    public func apply(to path: String) -> String? {
        let local = Self.trimmed(localPrefix)
        let remote = Self.trimmed(remotePrefix)
        guard !local.isEmpty else { return nil }
        if path == local { return remote }
        let withSlash = local == "/" ? "/" : local + "/"
        guard path.hasPrefix(withSlash) else { return nil }
        let rest = path.dropFirst(withSlash.count)
        return remote == "/" ? "/" + rest : remote + "/" + rest
    }
}

public extension Array where Element == PathRemap {
    /// Longest matching local prefix wins; unmatched paths pass through.
    func remap(_ path: String) -> String {
        let candidates = self
            .filter { $0.apply(to: path) != nil }
            .sorted { PathRemap.trimmed($0.localPrefix).count > PathRemap.trimmed($1.localPrefix).count }
        return candidates.first?.apply(to: path) ?? path
    }
}
