// swift-tools-version:5.9
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
import PackageDescription

// SendEhrKit: the "Send to Arena" logic for Resolume Arena, shared by SendEhr
// (Finder Sync extension + menu bar host) and other hosts such as MaCrate.
// Consume by URL + tag, e.g.
//   .package(url: "https://github.com/AmritusG/sendehr-public.git", exact: "1.1.1")
//
// The test target is declared only where Tests/ exists (the public source
// tree ships without tests).
let hasTests = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Tests/SendEhrKitTests")

let package = Package(
    name: "SendEhrKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SendEhrKit", targets: ["SendEhrKit"]),
        .library(name: "SendEhrKitUI", targets: ["SendEhrKitUI"]),
    ],
    targets: [
        // Core: Foundation only (no AppKit / SwiftUI).
        .target(name: "SendEhrKit"),
        // AppKit NSMenu builder (Finder Sync) + SwiftUI menu (MaCrate).
        .target(name: "SendEhrKitUI", dependencies: ["SendEhrKit"]),
    ] + (hasTests ? [
        .testTarget(name: "SendEhrKitTests", dependencies: ["SendEhrKit", "SendEhrKitUI"]),
    ] : [])
)
