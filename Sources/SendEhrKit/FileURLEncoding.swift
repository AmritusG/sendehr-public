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

/// Builds the `file:///` body Arena's `/clips/{C}/open` expects.
/// Spec: Arena's swagger.yaml, FileUrl - three slashes, forward
/// slashes, every special character percent-encoded (space -> %20,
/// # -> %23, % -> %25, & -> %26, ? -> %3F). Non-ASCII is UTF-8 percent-encoded.
public enum ArenaFileURL {
    /// RFC 3986 unreserved characters plus the path separator.
    private static let allowed: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        return set
    }()

    /// `/Volumes/Media/My Videos/a b.mov` -> `file:///Volumes/Media/My%20Videos/a%20b.mov`.
    /// The path is NFC-normalised first so a Finder (NFD) name and a typed
    /// name encode identically.
    public static func encode(path: String) -> String {
        let normalized = path.precomposedStringWithCanonicalMapping
        let absolute = normalized.hasPrefix("/") ? normalized : "/" + normalized
        let encoded = absolute.addingPercentEncoding(withAllowedCharacters: allowed) ?? absolute
        return "file://" + encoded
    }

    /// Inverse of `encode`, for log lines and slot checks.
    public static func decode(_ url: String) -> String? {
        guard url.hasPrefix("file://") else { return nil }
        return String(url.dropFirst("file://".count)).removingPercentEncoding
    }
}
