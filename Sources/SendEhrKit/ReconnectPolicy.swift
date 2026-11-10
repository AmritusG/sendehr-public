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

/// When `CompositionStore` tries the websocket again after it failed or closed.
///
/// - Local Arena not running: no retries at all. The host app observes Arena's
///   launch (NSWorkspace didLaunchApplicationNotification, posted for regular
///   apps; Arena has no LSUIElement) and calls `CompositionStore.arenaLaunched()`.
/// - Just launched: Arena's webserver answers ~10 s after launch (measured 10.4 s),
///   so retry every `startupInterval` for `startupWindow` seconds.
/// - Otherwise (remote host, or local Arena running with its webserver off, or
///   still quitting): exponential backoff 1, 2, 4 ... seconds, capped at `cap`.
///   A menu opened while disconnected also retries at once (`wake()`).
public struct ReconnectPolicy: Sendable, Equatable {
    public var startupWindow: TimeInterval = 60
    public var startupInterval: TimeInterval = 1
    public var cap: TimeInterval = 30

    public init() {}

    /// - Parameters:
    ///   - local: the endpoint is this Mac.
    ///   - arenaRunning: Arena's process is running on this Mac (nil = unknown).
    ///   - failures: consecutive failed attempts, 1 for the first.
    ///   - sinceLaunch: seconds since Arena's launch was observed, nil if not observed.
    /// - Returns: seconds until the next attempt, nil = wait for Arena's launch.
    public func delay(local: Bool, arenaRunning: Bool?, failures: Int, sinceLaunch: TimeInterval?) -> TimeInterval? {
        if local && arenaRunning == false { return nil }
        if let s = sinceLaunch, s < startupWindow { return startupInterval }
        let exponent = Double(max(0, min(failures - 1, 16)))
        return min(pow(2, exponent), cap)
    }
}
