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

/// File types Arena loads into a clip slot. Source: the file-dialog filters
/// compiled into Arena 7.28.1.
/// `.avc` is a composition, not a clip, and is deliberately absent.
public enum ArenaMediaTypes {
    public static let video: Set<String> = ["mov", "mp4", "avi", "mpg", "mpeg", "gif", "wmv"]
    public static let image: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "psd", "exr"]
    public static let audio: Set<String> = ["wav", "aiff", "aif", "flac", "ogg"]
    public static let all: Set<String> = video.union(image).union(audio)

    public static func isSupported(_ url: URL) -> Bool {
        guard url.isFileURL, !url.hasDirectoryPath else { return false }
        return all.contains(url.pathExtension.lowercased())
    }

    public static func isSupported(path: String) -> Bool {
        all.contains((path as NSString).pathExtension.lowercased())
    }
}
