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

public struct ArenaProduct: Codable, Equatable, Sendable {
    public var name: String
    public var major: Int
    public var minor: Int
    public var micro: Int
    public var revision: Int
    public var versionString: String { "\(name) \(major).\(minor).\(micro) (\(revision))" }
}

/// Connection state as the menus show it.
public enum ArenaStatus: Codable, Equatable, Sendable {
    case connected(product: String)
    case failed(ArenaError)
    case unknown

    public var isConnected: Bool { if case .connected = self { return true } else { return false } }

    public var plainLine: String {
        switch self {
        case let .connected(p): return "Connected to \(p)"
        case let .failed(e): return e.plainLine
        case .unknown: return "Checking Arena..."
        }
    }
}

extension ArenaError: Codable {
    private enum K: String, Codable { case notRunning, webserverOff, unreachable, http, badResponse, layerGone, noFiles, cancelled }
    private struct Box: Codable { var k: K; var host: String?; var port: Int?; var text: String?; var status: Int?; var id: Int64? }
    public init(from decoder: Decoder) throws {
        let b = try Box(from: decoder)
        switch b.k {
        case .notRunning: self = .notRunning
        case .webserverOff: self = .webserverOff(host: b.host ?? "", port: b.port ?? 0)
        case .unreachable: self = .unreachable(host: b.host ?? "", port: b.port ?? 0, detail: b.text ?? "")
        case .http: self = .http(status: b.status ?? 0, path: b.host ?? "", body: b.text ?? "")
        case .badResponse: self = .badResponse(b.text ?? "")
        case .layerGone: self = .layerGone(layerID: b.id ?? 0)
        case .noFiles: self = .noFiles
        case .cancelled: self = .cancelled
        }
    }
    public func encode(to encoder: Encoder) throws {
        let b: Box
        switch self {
        case .notRunning: b = Box(k: .notRunning)
        case let .webserverOff(h, p): b = Box(k: .webserverOff, host: h, port: p)
        case let .unreachable(h, p, d): b = Box(k: .unreachable, host: h, port: p, text: d)
        case let .http(s, path, body): b = Box(k: .http, host: path, text: body, status: s)
        case let .badResponse(t): b = Box(k: .badResponse, text: t)
        case let .layerGone(id): b = Box(k: .layerGone, id: id)
        case .noFiles: b = Box(k: .noFiles)
        case .cancelled: b = Box(k: .cancelled)
        }
        try b.encode(to: encoder)
    }
}

/// REST client for the endpoints SendEhr uses, as documented in the swagger.yaml
/// that Arena's webserver serves.
public struct ArenaClient: Sendable {
    public var endpoint: ArenaEndpoint
    /// Answers "is the Arena process running on this Mac?" (AppKit lives in
    /// the caller). nil = unknown (e.g. a remote host).
    public var isArenaProcessRunning: @Sendable () -> Bool?
    private let session: URLSession

    public init(endpoint: ArenaEndpoint, isArenaProcessRunning: @escaping @Sendable () -> Bool? = { nil }) {
        self.init(endpoint: endpoint, isArenaProcessRunning: isArenaProcessRunning, protocolClasses: nil)
    }

    /// `protocolClasses`: tests route requests to an in-process fake Arena.
    init(endpoint: ArenaEndpoint, isArenaProcessRunning: @escaping @Sendable () -> Bool? = { nil }, protocolClasses: [AnyClass]?) {
        self.endpoint = endpoint
        self.isArenaProcessRunning = isArenaProcessRunning
        let cfg = URLSessionConfiguration.ephemeral
        if let protocolClasses { cfg.protocolClasses = protocolClasses }
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 60
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
    }

    // MARK: transport

    @discardableResult
    func request(_ method: String, _ path: String, body: Data? = nil, contentType: String? = nil) async throws -> Data {
        var req = URLRequest(url: endpoint.apiBase.appendingPathComponent(String(path.drop { $0 == "/" })))
        req.httpMethod = method
        if let body { req.httpBody = body }
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch { throw mapTransport(error) }
        guard let http = response as? HTTPURLResponse else { throw ArenaError.badResponse("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw ArenaError.http(status: http.statusCode, path: path,
                                  body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }

    func mapTransport(_ error: Error) -> ArenaError {
        if error is CancellationError { return .cancelled }
        let code = (error as? URLError)?.code
        switch code {
        case .cannotConnectToHost?, .networkConnectionLost?:
            if endpoint.isLocal {
                return isArenaProcessRunning() == false ? .notRunning : .webserverOff(host: endpoint.host, port: endpoint.port)
            }
            return .unreachable(host: endpoint.host, port: endpoint.port, detail: "connection refused (webserver off or Arena closed)")
        case .timedOut?:
            return .unreachable(host: endpoint.host, port: endpoint.port, detail: "timed out")
        case .cannotFindHost?, .dnsLookupFailed?:
            return .unreachable(host: endpoint.host, port: endpoint.port, detail: "host not found")
        default:
            return .unreachable(host: endpoint.host, port: endpoint.port, detail: error.localizedDescription)
        }
    }

    // MARK: reads

    /// `GET /product`.
    public func product() async throws -> ArenaProduct {
        let data = try await request("GET", "/product")
        do { return try JSONDecoder().decode(ArenaProduct.self, from: data) }
        catch { throw ArenaError.badResponse("product: \(error.localizedDescription)") }
    }

    public func status() async -> ArenaStatus {
        do { return .connected(product: try await product().versionString) }
        catch let e as ArenaError { return .failed(e) }
        catch { return .failed(.badResponse(error.localizedDescription)) }
    }

    /// `GET /composition` reduced to a snapshot. The ~29 MB body is
    /// downloaded to a temporary file and scanned through a read-only memory
    /// map: file-backed clean pages, so it never lands in the host's dirty heap.
    public func snapshot() async throws -> CompositionSnapshot {
        let req = URLRequest(url: endpoint.apiBase.appendingPathComponent("composition"))
        let file: URL, response: URLResponse
        do { (file, response) = try await session.download(for: req) }
        catch { throw mapTransport(error) }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse else { throw ArenaError.badResponse("no HTTP response") }
        let data: Data
        do { data = try Data(contentsOf: file, options: .alwaysMapped) }
        catch { throw ArenaError.badResponse("composition download: \(error.localizedDescription)") }
        guard (200..<300).contains(http.statusCode) else {
            throw ArenaError.http(status: http.statusCode, path: "/composition",
                                  body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try CompositionDecoder.decode(data)
    }

    /// `GET /composition/layers/{L}/clips/{C}` - slot check.
    public func slot(layer: Int, column: Int) async throws -> SlotInfo {
        let data = try await request("GET", "/composition/layers/\(layer)/clips/\(column)")
        struct P<T: Decodable>: Decodable { let value: T? }
        struct C: Decodable { let id: Int64; let name: P<String>?; let connected: P<String>? }
        do {
            let c = try JSONDecoder().decode(C.self, from: data)
            let state = c.connected?.value ?? "Empty"
            return SlotInfo(column: column, clipID: c.id, clipName: state == "Empty" ? nil : c.name?.value, state: state)
        } catch { throw ArenaError.badResponse("clip: \(error.localizedDescription)") }
    }

    // MARK: writes

    /// `POST /composition/layers/add`, empty body = at the end / top.
    public func addLayer() async throws { try await request("POST", "/composition/layers/add") }

    /// `POST /composition/columns/add`, empty body = at the end.
    public func addColumn() async throws { try await request("POST", "/composition/columns/add") }

    /// `POST /composition/layers/{L}/clips/{C}/open`, text/plain file URL.
    public func open(layer: Int, column: Int, path: String) async throws {
        try await request("POST", "/composition/layers/\(layer)/clips/\(column)/open",
                          body: Data(ArenaFileURL.encode(path: path).utf8), contentType: "text/plain")
    }

    /// `POST /composition/layers/{L}/clips/{C}/connect`, no body = short click.
    public func connect(layer: Int, column: Int) async throws {
        try await request("POST", "/composition/layers/\(layer)/clips/\(column)/connect")
    }

    /// `PUT /composition/layers/by-id/{id}` `{"name":{"value":...}}` (answers 204).
    public func renameLayer(id: Int64, name: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": ["value": name]])
        try await request("PUT", "/composition/layers/by-id/\(id)", body: body, contentType: "application/json")
    }

    /// `DELETE /composition/layers/by-id/{id}`.
    public func deleteLayer(id: Int64) async throws { try await request("DELETE", "/composition/layers/by-id/\(id)") }

    /// `DELETE /composition/columns/by-id/{id}`.
    public func deleteColumn(id: Int64) async throws { try await request("DELETE", "/composition/columns/by-id/\(id)") }
}
