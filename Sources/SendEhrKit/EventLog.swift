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

/// Ring buffer of the last 500 events, for the log window's Copy All.
public final class EventLog: @unchecked Sendable {
    public struct Entry: Sendable {
        public let date: Date
        public let text: String
    }

    public static let capacity = 500
    private let lock = NSLock()
    private var entries: [Entry] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private var observers: [@Sendable (Entry) -> Void] = []
    private var fileHandle: FileHandle?

    public init() {}

    public func add(_ text: String) {
        let e = Entry(date: Date(), text: text)
        lock.lock()
        entries.append(e)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        let obs = observers
        let fh = fileHandle
        lock.unlock()
        fh?.write(Data((line(e) + "\n").utf8))
        obs.forEach { $0(e) }
    }

    /// Called on any thread after each append.
    public func observe(_ f: @escaping @Sendable (Entry) -> Void) {
        lock.lock(); observers.append(f); lock.unlock()
    }

    /// Also append every event to a plain text file (e.g. ~/Library/Logs/SendEhr/SendEhr.log).
    public func mirror(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let fh = try? FileHandle(forWritingTo: url) else { return }
        fh.seekToEndOfFile()
        lock.lock(); fileHandle = fh; lock.unlock()
    }

    public var all: [Entry] { lock.lock(); defer { lock.unlock() }; return entries }

    public func line(_ e: Entry) -> String { "\(formatter.string(from: e.date))  \(e.text)" }

    public var text: String { all.map(line).joined(separator: "\n") }
}
