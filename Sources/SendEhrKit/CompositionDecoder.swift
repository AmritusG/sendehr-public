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

/// Reads only the fields SendEhr needs out of Arena's full composition JSON
/// (swagger.yaml schemas Composition, Layer, Column, Clip)
/// with a single forward byte scan over the message, in place: no copy of the
/// ~29 MB document, no JSON tree, no Codable intermediates. Everything outside
/// the wanted paths is skipped byte-wise. Allocations = the snapshot itself.
public enum CompositionDecoder {
    /// True for a websocket frame that carries a full composition (no `type`,
    /// has `columns` and `layers`; Arena example `resolume_provider.tsx`).
    /// Full compositions start with the composition name param.
    public static func looksLikeComposition(_ bytes: UnsafeRawBufferPointer) -> Bool {
        let prefix = Array("{\"name\":".utf8)
        guard bytes.count >= prefix.count else { return false }
        for (i, b) in prefix.enumerated() where bytes[i] != b { return false }
        return true
    }

    public static func looksLikeComposition(_ data: Data) -> Bool {
        data.withUnsafeBytes { looksLikeComposition($0) }
    }

    public static func decode(_ data: Data) throws -> CompositionSnapshot {
        try data.withUnsafeBytes { try decode($0) }
    }

    public static func decode(_ bytes: UnsafeRawBufferPointer) throws -> CompositionSnapshot {
        var s = LeanScanner(bytes)
        do { return try s.composition() }
        catch let e as LeanScanner.Failure {
            throw ArenaError.badResponse("composition JSON: \(e.message) at byte \(e.offset)")
        }
    }
}

/// Minimal forward-only JSON reader for the composition shape.
struct LeanScanner {
    struct Failure: Error { let message: String; let offset: Int }

    private let p: UnsafeRawBufferPointer
    private var i = 0

    init(_ bytes: UnsafeRawBufferPointer) { p = bytes }

    // MARK: composition shape

    mutating func composition() throws -> CompositionSnapshot {
        var compName = ""
        var deckName = ""
        var layers: [LayerInfo] = []
        var columns: [ColumnInfo] = []
        var sawLayers = false, sawColumns = false
        try object { s, key in
            switch key {
            case .name: compName = try s.param().string ?? ""
            case .decks:
                try s.array { s in
                    var name: String?, selected = false
                    try s.object { s, k in
                        switch k {
                        case .name: name = try s.param().string
                        case .selected: selected = try s.param().bool ?? false
                        default: try s.skipValue()
                        }
                    }
                    if selected, deckName.isEmpty { deckName = name ?? "" }
                }
            case .layers:
                sawLayers = true
                try s.array { s in layers.append(try s.layer(index: layers.count + 1)) }
            case .columns:
                sawColumns = true
                try s.array { s in
                    var id: Int64?, name: (string: String?, bool: Bool?, id: Int64?) = (nil, nil, nil)
                    try s.object { s, k in
                        switch k {
                        case .id: id = try s.int64()
                        case .name: name = try s.param()
                        default: try s.skipValue()
                        }
                    }
                    guard let id else { throw s.fail("column without id") }
                    columns.append(ColumnInfo(index: columns.count + 1, id: id,
                                              rawName: name.string ?? "Column #", nameParamID: name.id))
                }
            default: try s.skipValue()
            }
        }
        guard sawLayers, sawColumns else { throw fail("no layers/columns") }
        return CompositionSnapshot(compositionName: compName, deckName: deckName,
                                   layers: layers, columns: columns)
    }

    private mutating func layer(index: Int) throws -> LayerInfo {
        var id: Int64?
        var name: (string: String?, bool: Bool?, id: Int64?) = (nil, nil, nil)
        var slots: [SlotInfo] = []
        try object { s, k in
            switch k {
            case .id: id = try s.int64()
            case .name: name = try s.param()
            case .clips:
                try s.array { s in
                    var cid: Int64?, cname: String?, state = "Empty"
                    try s.object { s, k in
                        switch k {
                        case .id: cid = try s.int64()
                        case .name: cname = try s.param().string
                        case .connected: state = try s.param().string ?? "Empty"
                        default: try s.skipValue()
                        }
                    }
                    guard let cid else { throw s.fail("clip without id") }
                    slots.append(SlotInfo(column: slots.count + 1, clipID: cid,
                                          clipName: state == "Empty" ? nil : (cname?.isEmpty == false ? cname : nil),
                                          state: state))
                }
            default: try s.skipValue()
            }
        }
        guard let id else { throw fail("layer without id") }
        return LayerInfo(index: index, id: id, rawName: name.string ?? "Layer #", nameParamID: name.id, slots: slots)
    }

    /// A parameter object `{"value": ..., "id": ...}`; other members skipped.
    private mutating func param() throws -> (string: String?, bool: Bool?, id: Int64?) {
        var str: String?, bool: Bool?, id: Int64?
        if peekNull() { try skipValue(); return (nil, nil, nil) }
        try object { s, k in
            switch k {
            case .value:
                switch s.peek() {
                case UInt8(ascii: "\""): str = try s.string()
                case UInt8(ascii: "t"), UInt8(ascii: "f"): bool = try s.boolean()
                default: try s.skipValue()
                }
            case .id: id = try s.int64()
            default: try s.skipValue()
            }
        }
        return (str, bool, id)
    }

    // MARK: keys

    enum Key { case name, decks, layers, columns, id, clips, connected, selected, value, other }

    private static let keyTable: [([UInt8], Key)] = {
        let pairs: [(String, Key)] = [
            ("name", .name), ("decks", .decks), ("layers", .layers), ("columns", .columns), ("id", .id),
            ("clips", .clips), ("connected", .connected), ("selected", .selected), ("value", .value),
        ]
        return pairs.map { (Array($0.0.utf8), $0.1) }
    }()

    /// Reads a member key (no unescaping needed: wanted keys are plain ASCII).
    private mutating func key() throws -> Key {
        try expect(UInt8(ascii: "\""))
        let start = i
        while i < p.count, p[i] != UInt8(ascii: "\"") {
            if p[i] == UInt8(ascii: "\\") { i += 1 }
            i += 1
        }
        guard i < p.count else { throw fail("unterminated key") }
        let len = i - start
        i += 1
        for (bytes, k) in Self.keyTable where bytes.count == len {
            var eq = true
            for j in 0..<len where p[start + j] != bytes[j] { eq = false; break }
            if eq { return k }
        }
        return .other
    }

    // MARK: structure

    private mutating func object(_ member: (inout LeanScanner, Key) throws -> Void) throws {
        try expect(UInt8(ascii: "{"))
        ws()
        if peek() == UInt8(ascii: "}") { i += 1; return }
        while true {
            ws()
            let k = try key()
            ws(); try expect(UInt8(ascii: ":")); ws()
            try member(&self, k)
            ws()
            guard i < p.count else { throw fail("unterminated object") }
            let c = p[i]; i += 1
            if c == UInt8(ascii: "}") { return }
            if c != UInt8(ascii: ",") { throw fail("expected , or }") }
        }
    }

    private mutating func array(_ element: (inout LeanScanner) throws -> Void) throws {
        if peekNull() { try skipValue(); return }
        try expect(UInt8(ascii: "["))
        ws()
        if peek() == UInt8(ascii: "]") { i += 1; return }
        while true {
            ws()
            try element(&self)
            ws()
            guard i < p.count else { throw fail("unterminated array") }
            let c = p[i]; i += 1
            if c == UInt8(ascii: "]") { return }
            if c != UInt8(ascii: ",") { throw fail("expected , or ]") }
        }
    }

    /// Skips one value of any kind. Containers are skipped by a depth count
    /// that ignores brackets inside strings.
    mutating func skipValue() throws {
        ws()
        guard i < p.count else { throw fail("value expected") }
        let c = p[i]
        if c == UInt8(ascii: "\"") { try skipString(); return }
        if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") {
            var depth = 0
            while i < p.count {
                let b = p[i]
                switch b {
                case UInt8(ascii: "\""): try skipString(); continue
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { i += 1; return }
                default: break
                }
                i += 1
            }
            throw fail("unterminated container")
        }
        // number / true / false / null
        while i < p.count {
            let b = p[i]
            if b == UInt8(ascii: ",") || b == UInt8(ascii: "}") || b == UInt8(ascii: "]") || b <= 0x20 { return }
            i += 1
        }
    }

    private mutating func skipString() throws {
        i += 1  // opening quote
        while i < p.count {
            let b = p[i]
            if b == UInt8(ascii: "\\") { i += 2; continue }
            i += 1
            if b == UInt8(ascii: "\"") { return }
        }
        throw fail("unterminated string")
    }

    // MARK: scalars

    private mutating func string() throws -> String {
        try expect(UInt8(ascii: "\""))
        let start = i
        var escaped = false
        while i < p.count, p[i] != UInt8(ascii: "\"") {
            if p[i] == UInt8(ascii: "\\") { escaped = true; i += 1 }
            i += 1
        }
        guard i < p.count else { throw fail("unterminated string") }
        let raw = UnsafeRawBufferPointer(rebasing: p[start..<i])
        i += 1
        if !escaped { return String(decoding: raw, as: UTF8.self) }
        return try unescape(raw)
    }

    private func unescape(_ raw: UnsafeRawBufferPointer) throws -> String {
        var out: [UInt8] = []
        out.reserveCapacity(raw.count)
        var j = 0
        func hex4(_ at: Int) throws -> UInt32 {
            guard at + 4 <= raw.count else { throw fail("bad \\u escape") }
            var v: UInt32 = 0
            for k in at..<(at + 4) {
                let h = raw[k]
                v <<= 4
                switch h {
                case 0x30...0x39: v |= UInt32(h - 0x30)
                case 0x41...0x46: v |= UInt32(h - 0x41 + 10)
                case 0x61...0x66: v |= UInt32(h - 0x61 + 10)
                default: throw fail("bad \\u escape")
                }
            }
            return v
        }
        while j < raw.count {
            let b = raw[j]
            guard b == UInt8(ascii: "\\"), j + 1 < raw.count else { out.append(b); j += 1; continue }
            let e = raw[j + 1]
            j += 2
            switch e {
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "u"):
                var scalar = try hex4(j); j += 4
                if (0xD800...0xDBFF).contains(scalar), j + 6 <= raw.count,
                   raw[j] == UInt8(ascii: "\\"), raw[j + 1] == UInt8(ascii: "u") {
                    let low = try hex4(j + 2)
                    if (0xDC00...0xDFFF).contains(low) {
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        j += 6
                    }
                }
                let u = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                out.append(contentsOf: Array(String(Character(u)).utf8))
            default: out.append(e)   // \" \\ \/
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private mutating func int64() throws -> Int64? {
        ws()
        if peekNull() { try skipValue(); return nil }
        var neg = false
        if peek() == UInt8(ascii: "-") { neg = true; i += 1 }
        var v: Int64 = 0
        var digits = 0
        while i < p.count, p[i] >= 0x30, p[i] <= 0x39 {
            let (m, o1) = v.multipliedReportingOverflow(by: 10)
            let (a, o2) = m.addingReportingOverflow(Int64(p[i] - 0x30))
            guard !o1, !o2 else { throw fail("integer overflow") }
            v = a; digits += 1; i += 1
        }
        guard digits > 0 else { throw fail("number expected") }
        // A fraction/exponent is not an id: consume it and give up on the value.
        if i < p.count, p[i] == UInt8(ascii: ".") || p[i] == UInt8(ascii: "e") || p[i] == UInt8(ascii: "E") {
            try skipValue(); return nil
        }
        return neg ? -v : v
    }

    private mutating func boolean() throws -> Bool {
        if matches("true") { i += 4; return true }
        if matches("false") { i += 5; return false }
        throw fail("bool expected")
    }

    // MARK: bytes

    private mutating func ws() {
        while i < p.count, p[i] == 0x20 || p[i] == 0x0A || p[i] == 0x0D || p[i] == 0x09 { i += 1 }
    }

    private func peek() -> UInt8 { i < p.count ? p[i] : 0 }

    private mutating func peekNull() -> Bool { ws(); return matches("null") }

    private func matches(_ word: StaticString) -> Bool {
        let n = word.utf8CodeUnitCount
        guard i + n <= p.count else { return false }
        let w = word.utf8Start
        for k in 0..<n where p[i + k] != w[k] { return false }
        return true
    }

    private mutating func expect(_ b: UInt8) throws {
        guard i < p.count, p[i] == b else { throw fail("expected '\(Character(Unicode.Scalar(b)))'") }
        i += 1
    }

    func fail(_ message: String) -> Failure { Failure(message: message, offset: i) }
}
