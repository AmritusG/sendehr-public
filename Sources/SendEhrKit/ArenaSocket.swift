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
import Network
import CryptoKit

/// Minimal RFC 6455 websocket client for Arena's `ws://host:port/api/v1`.
///
/// Why not URLSessionWebSocketTask: Arena pushes the full ~29 MB composition
/// as one text frame on every clip load (every ~5 s while its autopilot runs);
/// URLSession assembles each message in growing heap buffers and hands it over
/// as a String, leaving ~120 MB of freed-but-cached large blocks in the host
/// (measured). Here a frame's payload length is read
/// from its header (RFC 6455 5.2), the payload is received straight into one
/// buffer of exactly that size, scanned in place by the caller, and the buffer
/// is unmapped right after: the memory goes back to the OS per message.
///
/// All callbacks run on `queue`.
final class ArenaSocket: @unchecked Sendable {
    enum Event {
        case open
        /// Complete message (text or binary), valid only during the callback.
        case message(UnsafeRawBufferPointer)
        case closed(Error?)
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    private let host: String
    private let port: UInt16
    private let path: String
    private let queue: DispatchQueue
    private let handler: (Event) -> Void
    private var connection: NWConnection?
    private var closed = false
    private var key = ""

    // Frame state
    private var header = [UInt8]()
    private var message = MessageBuffer()
    private var frameRemaining = 0
    private var frameOpcode: UInt8 = 0
    private var frameFin = false
    private var control = [UInt8]()     // ping/close payloads (<= 125 bytes)
    private var inControl = false
    private(set) var messageFrames = 0  // frames in the current/last message (diagnostics)

    static let maxMessage = 512 * 1024 * 1024

    init(host: String, port: Int, path: String, queue: DispatchQueue, handler: @escaping (Event) -> Void) {
        self.host = host
        self.port = UInt16(clamping: port)
        self.path = path
        self.queue = queue
        self.handler = handler
    }

    func start() {
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 8080, using: .tcp)
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.sendHandshake()
            case let .failed(e): self.finish(e)
            case let .waiting(e): self.finish(e)   // refused: report now, the store reconnects
            case .cancelled: self.finish(nil)
            default: break
            }
        }
        c.start(queue: queue)
    }

    func cancel() {
        closed = true
        connection?.cancel()
        connection = nil
        message.release()
    }

    func sendText(_ text: String) {
        send(opcode: 0x1, payload: Array(text.utf8))
    }

    // MARK: handshake (RFC 6455 4.1)

    private func sendHandshake() {
        var nonce = [UInt8](repeating: 0, count: 16)
        for i in nonce.indices { nonce[i] = UInt8.random(in: 0...255) }
        key = Data(nonce).base64EncodedString()
        let req = "GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        connection?.send(content: Data(req.utf8), completion: .contentProcessed { [weak self] e in
            if let e { self?.finish(e) }
        })
        readHandshake(Data())
    }

    private func readHandshake(_ soFar: Data) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let error { self.finish(error); return }
            var buf = soFar
            if let data { buf.append(data) }
            guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if done || buf.count > 64 * 1024 { self.finish(Failure("websocket handshake: no response")); return }
                self.readHandshake(buf); return
            }
            let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
            guard head.hasPrefix("HTTP/1.1 101") else {
                self.finish(Failure("websocket handshake: \(head.prefix(60))")); return
            }
            let expected = Data(Insecure.SHA1.hash(data: Data((self.key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
                .base64EncodedString()
            let accept = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-accept:") }
                .map { $0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces) }
            guard accept == expected else { self.finish(Failure("websocket handshake: bad accept key")); return }
            self.handler(.open)
            let rest = buf[end.upperBound...]
            if !rest.isEmpty { rest.withUnsafeBytes { self.consume($0) } }
            self.readFrames()
        }
    }

    // MARK: frames (RFC 6455 5.2)

    private func readFrames() {
        guard let c = connection, !closed else { return }
        // Arena fragments a composition into ~64 KB frames (measured): read in
        // large chunks, headers and payloads are split out by consume().
        c.receive(minimumIncompleteLength: 1, maximumLength: 4 * 1024 * 1024) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let error { self.finish(error); return }
            if let data, !data.isEmpty {
                data.withUnsafeBytes { self.consume($0) }
            }
            if done { self.finish(nil); return }
            if !self.closed { self.readFrames() }
        }
    }

    private func consume(_ bytes: UnsafeRawBufferPointer) {
        var i = 0
        while i < bytes.count, !closed {
            if frameRemaining > 0 {
                let n = min(frameRemaining, bytes.count - i)
                let chunk = UnsafeRawBufferPointer(rebasing: bytes[i..<(i + n)])
                if inControl { control.append(contentsOf: chunk) } else { message.append(chunk) }
                frameRemaining -= n
                i += n
                if frameRemaining == 0 { frameDone() }
                continue
            }
            header.append(bytes[i]); i += 1
            parseHeaderIfComplete()
        }
    }

    private func parseHeaderIfComplete() {
        guard header.count >= 2 else { return }
        let masked = header[1] & 0x80 != 0
        let len7 = Int(header[1] & 0x7F)
        let extLen = len7 == 126 ? 2 : (len7 == 127 ? 8 : 0)
        let need = 2 + extLen + (masked ? 4 : 0)
        guard header.count >= need else { return }
        if masked { fail("masked server frame"); return }   // RFC 6455 5.1: servers never mask
        var length = len7
        if extLen > 0 {
            length = 0
            for k in 0..<extLen { length = length << 8 | Int(header[2 + k]) }
        }
        frameFin = header[0] & 0x80 != 0
        frameOpcode = header[0] & 0x0F
        header.removeAll(keepingCapacity: true)
        inControl = frameOpcode >= 0x8
        if inControl {
            guard length <= 125, frameFin else { fail("bad control frame"); return }
            control.removeAll(keepingCapacity: true)
        } else {
            guard message.count + length <= Self.maxMessage else { fail("message too large"); return }
            // Fragmented messages grow geometrically (no copy per fragment).
            message.reserve(message.count + length, geometric: message.count > 0)
            if frameOpcode != 0 { messageFrames = 0 }
            messageFrames += 1
        }
        frameRemaining = length
        if length == 0 { frameDone() }
    }

    private func frameDone() {
        if inControl {
            inControl = false
            switch frameOpcode {
            case 0x8: send(opcode: 0x8, payload: Array(control.prefix(2))); finish(nil)   // close echo
            case 0x9: send(opcode: 0xA, payload: control)                                 // ping -> pong
            default: break                                                                // pong
            }
            return
        }
        guard frameFin else { return }   // more continuation frames follow
        message.withBytes { handler(.message($0)) }
        message.release()
    }

    // MARK: send (client frames are masked, RFC 6455 5.3)

    private func send(opcode: UInt8, payload: [UInt8]) {
        guard let c = connection else { return }
        var frame: [UInt8] = [0x80 | opcode]
        let n = payload.count
        if n < 126 { frame.append(0x80 | UInt8(n)) }
        else if n <= 0xFFFF { frame += [0x80 | 126, UInt8(n >> 8), UInt8(n & 0xFF)] }
        else { frame.append(0x80 | 127); for k in (0..<8).reversed() { frame.append(UInt8((n >> (8 * k)) & 0xFF)) } }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame += mask
        frame += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        c.send(content: Data(frame), completion: .contentProcessed { _ in })
    }

    private func fail(_ reason: String) { finish(Failure("websocket: \(reason)")) }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        connection?.cancel()
        connection = nil
        message.release()
        handler(.closed(error))
    }
}

/// Message payload storage. Large messages live in an anonymous mapping that
/// is unmapped as soon as the message has been handled (pages return to the
/// OS at once, no malloc cache); small ones use the heap.
struct MessageBuffer {
    private var base: UnsafeMutableRawPointer?
    private var capacity = 0
    private var mapped = false
    private(set) var count = 0

    static let mapThreshold = 256 * 1024

    mutating func reserve(_ needed: Int, geometric: Bool = false) {
        guard needed > capacity else { return }
        let needed = geometric ? max(needed, capacity * 2) : needed
        let useMap = needed >= Self.mapThreshold
        let newCap = useMap ? (needed + Int(vm_page_size) - 1) / Int(vm_page_size) * Int(vm_page_size) : needed
        let p: UnsafeMutableRawPointer
        if useMap {
            guard let m = mmap(nil, newCap, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
                  m != MAP_FAILED else { return }
            p = m
        } else {
            p = UnsafeMutableRawPointer.allocate(byteCount: max(newCap, 1), alignment: 16)
        }
        if let base, count > 0 { p.copyMemory(from: base, byteCount: count) }
        freeStorage()
        base = p; capacity = newCap; mapped = useMap
    }

    mutating func append(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        if count + bytes.count > capacity { reserve(count + bytes.count, geometric: true) }
        guard let base, count + bytes.count <= capacity else { return }
        (base + count).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        count += bytes.count
    }

    func withBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: base, count: count))
    }

    mutating func release() {
        freeStorage()
        base = nil; capacity = 0; count = 0; mapped = false
    }

    private func freeStorage() {
        guard let base else { return }
        if mapped { munmap(base, capacity) } else { base.deallocate() }
    }
}
