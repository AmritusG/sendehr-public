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

/// Typed failures. `plainLine` is the one-line, user-facing text the menus
/// and the log show.
public enum ArenaError: Error, Equatable, Sendable {
    case notRunning
    case webserverOff(host: String, port: Int)
    case unreachable(host: String, port: Int, detail: String)
    case http(status: Int, path: String, body: String)
    case badResponse(String)
    case layerGone(layerID: Int64)
    case noFiles
    case cancelled

    public var plainLine: String {
        switch self {
        case .notRunning:
            return "Arena is not running - start Resolume Arena."
        case let .webserverOff(host, port):
            return "Arena's webserver is off - Arena > Preferences > Webserver: enable, port \(port) (\(host))."
        case let .unreachable(host, port, detail):
            return "Arena not reachable at \(host):\(port) - \(detail)"
        case let .http(status, path, body):
            let hint: String
            switch status {
            case 404: hint = "not found"
            case 412: hint = "Arena refused (composition locked or clip busy)"
            case 400: hint = "bad request"
            default: hint = "HTTP \(status)"
            }
            return "\(hint): \(path)\(body.isEmpty ? "" : " - \(body)")"
        case let .badResponse(detail):
            return "Unexpected answer from Arena: \(detail)"
        case let .layerGone(id):
            return "That layer no longer exists in Arena (id \(id)) - pick again."
        case .noFiles:
            return "No files Arena can open in the selection."
        case .cancelled:
            return "Cancelled."
        }
    }
}
