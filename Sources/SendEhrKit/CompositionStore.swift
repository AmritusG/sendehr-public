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

/// Keeps a `CompositionSnapshot` of the current deck. `mode` (the "Arena
/// Updates" setting) picks how:
/// - `.live`: the websocket below (default);
/// - `.onDemand`: no websocket; one REST fetch per `wake()` (a menu opening,
///   at most once per `menuFetchGap`) or `refresh(reason:)`;
/// - `.interval`: no websocket; a REST fetch every `interval` seconds plus on `wake()`.
/// `setMode` switches at once (socket, poll and timers are torn down and the
/// new mode starts), no restart. Live mode:
/// - websocket `ws://host:port/api/v1`: Arena pushes the full composition on
///   connect and after every structural change;
/// - layer + column name parameters are subscribed, because renames are only
///   sent as `parameter_update`;
/// - a GET /composition poll (`pollInterval`) as a safety net for clip renames,
///   only while the websocket is open and no push came lately;
/// - reconnects follow `policy` (`ReconnectPolicy`): while a local Arena is not
///   running nothing retries until the host reports its launch (`arenaLaunched()`).
/// `onChange` arrives on the main queue, only when the snapshot or the status
/// (or, outside live mode, `updatedAt`: the menus show "Updated n s ago")
/// differs from the last one delivered: Arena pushes the full composition on
/// every clip trigger, and most pushes differ only in live values (transport
/// positions) the snapshot does not hold.
public final class CompositionStore: @unchecked Sendable {
    public private(set) var snapshot: CompositionSnapshot?
    public private(set) var status: ArenaStatus = .unknown
    /// (snapshot, status, updatedAt).
    public var onChange: ((CompositionSnapshot?, ArenaStatus, Date?) -> Void)?
    public var log: EventLog?
    public var pollInterval: TimeInterval = 30
    public var policy = ReconnectPolicy()
    public private(set) var mode: ArenaUpdateMode
    /// Seconds between fetches in `.interval` mode.
    public private(set) var interval: TimeInterval
    /// When the last composition arrived (push or fetch), changed or not.
    public private(set) var updatedAt: Date?
    /// `wake()` fetches at most once per this many seconds (menus can open in bursts).
    public var menuFetchGap: TimeInterval = 2
    /// REST composition fetches started (tests, diagnostics).
    public private(set) var fetches = 0

    private var client: ArenaClient
    private let queue = DispatchQueue(label: "sendehr.store")
    private var socket: ArenaSocket?
    private var socketGeneration = 0
    private var pollTimer: DispatchSourceTimer?
    private var intervalTimer: DispatchSourceTimer?
    private var lastWakeFetch: Date?
    /// Outside live mode after Arena's launch: fetch again every
    /// `policy.startupInterval` until one succeeds (its webserver needs ~10 s).
    private var fetchUntilUp = false
    private var fetchRetry: DispatchWorkItem?
    private var failures = 0
    private var launchedAt: Date?
    private var retry: DispatchWorkItem?
    private var waitingForLaunch = false
    /// Websocket connect attempts (tests, diagnostics).
    public private(set) var attempts = 0
    private var subscribed: Set<Int64> = []
    private var refreshPending = false
    private var running = false
    private var lastPush: Date?
    private var delivered: (snapshot: CompositionSnapshot?, status: ArenaStatus, updatedAt: Date?)?
    /// Number of `onChange` deliveries (tests, diagnostics).
    public private(set) var deliveries = 0

    public init(client: ArenaClient, mode: ArenaUpdateMode = .live, interval: TimeInterval = 60) {
        self.client = client
        self.mode = mode
        self.interval = interval
    }

    public var endpoint: ArenaEndpoint { client.endpoint }

    /// What is running right now (tests, diagnostics): websocket object, interval timer, 30 s poll.
    public struct Activity: Equatable, Sendable {
        public var socket: Bool
        public var intervalTimer: Bool
        public var poll: Bool
    }

    public var activity: Activity {
        queue.sync { Activity(socket: socket != nil, intervalTimer: intervalTimer != nil, poll: pollTimer != nil) }
    }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            begin()
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
            end()
        }
    }

    /// Switches the update mode now: live opens the websocket; on demand and
    /// interval close it, fetch once, and interval starts its timer.
    public func setMode(_ newMode: ArenaUpdateMode, interval newInterval: TimeInterval) {
        queue.async { [self] in
            guard newMode != mode || (newMode == .interval && newInterval != interval) else { return }
            mode = newMode
            interval = max(0.05, newInterval)   // settings clamp to >= 1 s; tests use less
            switch newMode {
            case .live: log?.add("Arena Updates: Live (websocket open)")
            case .onDemand: log?.add("Arena Updates: On Demand (websocket closed, fetch on menu open)")
            case .interval: log?.add("Arena Updates: every \(Int(interval)) s (websocket closed, timer \(Int(interval)) s)")
            }
            guard running else { return }
            end()
            failures = 0
            waitingForLaunch = false
            // A switch inside Arena's startup window keeps retrying until its webserver answers.
            if newMode != .live, let since = launchedAt.map({ Date().timeIntervalSince($0) }), since < policy.startupWindow {
                fetchUntilUp = true
            }
            begin()
        }
    }

    /// Starts the current mode (store queue).
    private func begin() {
        switch mode {
        case .live:
            openSocket()
        case .onDemand:
            scheduleRefresh(reason: "on demand")
        case .interval:
            scheduleRefresh(reason: "interval")
            startIntervalTimer()
        }
    }

    /// Stops every mode's socket, timers and retries (store queue).
    private func end() {
        closeSocket()
        retry?.cancel(); retry = nil
        intervalTimer?.cancel(); intervalTimer = nil
        fetchRetry?.cancel(); fetchRetry = nil
        fetchUntilUp = false
        lastPush = nil
    }

    /// Switch host/port: drops the cache and reconnects.
    public func setClient(_ newClient: ArenaClient) {
        queue.async { [self] in
            client = newClient
            snapshot = nil
            publish(status: .unknown)
            end()
            failures = 0
            launchedAt = nil
            if running { begin() }
        }
    }

    /// The host saw Arena launch on this Mac: connect now, then retry every
    /// `policy.startupInterval` until its webserver answers. Ignored for a remote endpoint.
    public func arenaLaunched() {
        queue.async { [self] in
            guard running, client.endpoint.isLocal else { return }
            log?.add("Arena launched - connecting")
            launchedAt = Date()
            failures = 0
            if mode == .live {
                connectNow()
            } else {
                fetchUntilUp = true
                scheduleRefresh(reason: "Arena launched")
            }
        }
    }

    /// The host saw Arena quit on this Mac: drop pending retries; the next
    /// failure (or this status check) finds it not running and waits.
    public func arenaTerminated() {
        queue.async { [self] in
            guard running, client.endpoint.isLocal else { return }
            launchedAt = nil
            fetchUntilUp = false
            fetchRetry?.cancel(); fetchRetry = nil
            guard socket == nil else { return }   // the open socket reports its own close
            retry?.cancel(); retry = nil
            checkStatusAndScheduleRetry()
        }
    }

    /// A menu is opening. Live: if disconnected, try once now (no-op while an
    /// attempt is in flight). On demand / interval: fetch, at most once per `menuFetchGap`.
    public func wake() {
        queue.async { [self] in
            guard running else { return }
            if mode != .live {
                let now = Date()
                if let last = lastWakeFetch, now.timeIntervalSince(last) < menuFetchGap { return }
                lastWakeFetch = now
                scheduleRefresh(reason: "menu")
                return
            }
            guard socket == nil, !status.isConnected else { return }
            connectNow()
        }
    }

    private func connectNow() {
        retry?.cancel(); retry = nil
        guard socket == nil else { return }
        openSocket()
    }

    /// Fetch now, unthrottled (after our own loads, or Refresh).
    public func refresh(reason: String) {
        queue.async { [self] in scheduleRefresh(reason: reason) }
    }

    // MARK: websocket

    private func openSocket() {
        socketGeneration += 1
        let gen = socketGeneration
        let ep = client.endpoint
        let sock = ArenaSocket(host: ep.host, port: ep.port, path: "/api/v1", queue: queue) { [weak self] event in
            guard let self, gen == self.socketGeneration else { return }
            switch event {
            case .open:
                self.failures = 0
                self.launchedAt = nil
                self.waitingForLaunch = false
                self.startPoll()
            case let .message(bytes): self.handle(bytes)
            case let .closed(error): self.socketFailed(error)
            }
        }
        socket = sock
        subscribed = []
        attempts += 1
        sock.start()
    }

    private func closeSocket() {
        socketGeneration += 1
        socket?.cancel()
        socket = nil
        pollTimer?.cancel(); pollTimer = nil
    }

    private func socketFailed(_ error: Error?) {
        closeSocket()
        lastPush = nil
        guard running else { return }
        failures += 1
        checkStatusAndScheduleRetry()
    }

    /// Publishes the REST status, then schedules the next attempt per `policy`
    /// (or none while a local Arena is not running).
    private func checkStatusAndScheduleRetry() {
        Task { [client] in
            let st = await client.status()
            let arenaRunning = client.isArenaProcessRunning()
            self.queue.async {
                guard self.running, self.socket == nil else { return }
                if !st.isConnected { self.snapshot = nil }
                self.publish(status: st)
                guard self.mode == .live else { return }   // other modes fetch on their own schedule
                let since = self.launchedAt.map { Date().timeIntervalSince($0) }
                guard let delay = self.policy.delay(local: client.endpoint.isLocal, arenaRunning: arenaRunning,
                                                    failures: max(self.failures, 1), sinceLaunch: since) else {
                    if !self.waitingForLaunch { self.log?.add("Waiting for Arena to launch (no retries until then)") }
                    self.waitingForLaunch = true
                    return
                }
                self.waitingForLaunch = false
                self.retry?.cancel()
                let work = DispatchWorkItem {
                    guard self.running, self.socket == nil else { return }
                    self.retry = nil
                    self.openSocket()
                }
                self.retry = work
                self.queue.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }

    /// One complete websocket message, scanned in place (ArenaSocket unmaps
    /// the buffer after this returns). A full composition is ~18 MB and arrives
    /// on every clip load (every ~5 s while Arena's autopilot runs).
    private func handle(_ bytes: UnsafeRawBufferPointer) {
        if CompositionDecoder.looksLikeComposition(bytes) {
            do {
                let snap = try CompositionDecoder.decode(bytes)
                // A quitting Arena pushes an empty composition ("" , 0 layers, 0 columns,
                // observed) for ~13 s while it saves; a real one always
                // has at least one layer and one column. Keep the last real snapshot.
                if snap.layers.isEmpty && snap.columns.isEmpty { return }
                lastPush = Date()
                apply(snap, source: "websocket")
            } catch {
                log?.add("websocket composition decode failed: \(error)")
            }
            return
        }
        // Small typed messages only (parameter updates); skip sources/effects lists.
        guard bytes.count < 64 * 1024,
              let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let type = obj["type"] as? String else { return }
        if type == "parameter_update" || type == "parameter_subscribed",
           let id = (obj["id"] as? NSNumber)?.int64Value, let value = obj["value"] as? String {
            applyRename(paramID: id, value: value)
        }
    }

    private func applyRename(paramID: Int64, value: String) {
        guard var snap = snapshot else { return }
        var changed = false
        for i in snap.layers.indices where snap.layers[i].nameParamID == paramID && snap.layers[i].rawName != value {
            snap.layers[i].rawName = value; changed = true
        }
        for i in snap.columns.indices where snap.columns[i].nameParamID == paramID && snap.columns[i].rawName != value {
            snap.columns[i].rawName = value; changed = true
        }
        if changed {
            snapshot = snap
            log?.add("Renamed in Arena -> \"\(value)\"")
            publish(status: status)
        }
    }

    private func subscribeNames(_ snap: CompositionSnapshot) {
        guard let task = socket else { return }
        let ids = Set(snap.layers.compactMap(\.nameParamID) + snap.columns.compactMap(\.nameParamID))
        for id in ids.subtracting(subscribed) {
            task.sendText("{\"action\":\"subscribe\",\"parameter\":\"/parameter/by-id/\(id)\"}")
        }
        subscribed.formUnion(ids)
    }

    // MARK: poll

    private func startPoll() {
        pollTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // Pushes already carry everything; poll only when none came lately
            // (clip renames are not pushed).
            if let last = self.lastPush, Date().timeIntervalSince(last) < self.pollInterval { return }
            self.scheduleRefresh(reason: "poll")
        }
        t.resume()
        pollTimer = t
    }

    /// Interval mode: a fetch every `interval` seconds. While a local Arena is
    /// not running the tick publishes "not running" without touching the network.
    private func startIntervalTimer() {
        intervalTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        t.setEventHandler { [weak self] in
            guard let self, self.running, self.mode == .interval else { return }
            if self.client.endpoint.isLocal, self.client.isArenaProcessRunning() == false {
                self.snapshot = nil
                self.publish(status: .failed(.notRunning))
                return
            }
            self.scheduleRefresh(reason: "interval")
        }
        t.resume()
        intervalTimer = t
    }

    /// One REST fetch (download to a temp file, mmap, in-place scan).
    /// Coalesced: a call while one is in flight is dropped.
    private func scheduleRefresh(reason: String) {
        guard !refreshPending else { return }
        refreshPending = true
        fetches += 1
        Task { [client] in
            do {
                let snap = try await client.snapshot()
                self.queue.async {
                    self.refreshPending = false
                    self.fetchUntilUp = false
                    self.apply(snap, source: reason)
                }
            } catch let e as ArenaError {
                self.queue.async {
                    self.refreshPending = false
                    self.snapshot = nil
                    self.publish(status: .failed(e))
                    self.retryFetchWhileStarting()
                }
            } catch {
                self.queue.async { self.refreshPending = false }
            }
        }
    }

    /// Outside live mode, after Arena's launch: fetch again until its webserver answers.
    private func retryFetchWhileStarting() {
        guard fetchUntilUp, running, mode != .live else { return }
        guard let since = launchedAt.map({ Date().timeIntervalSince($0) }), since < policy.startupWindow else {
            fetchUntilUp = false
            return
        }
        fetchRetry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.fetchUntilUp else { return }
            self.fetchRetry = nil
            self.scheduleRefresh(reason: "Arena launched")
        }
        fetchRetry = work
        queue.asyncAfter(deadline: .now() + policy.startupInterval, execute: work)
    }

    private func apply(_ snap: CompositionSnapshot, source: String) {
        // Log only what a person would notice (comp/deck/layer/column count);
        // clip state changes arrive every few seconds and stay silent.
        let structural = snapshot.map {
            $0.layers.count != snap.layers.count || $0.columns.count != snap.columns.count
                || $0.compositionName != snap.compositionName || $0.deckName != snap.deckName
        } ?? true
        if snapshot != snap { snapshot = snap }
        updatedAt = Date()
        if structural {
            log?.add("Composition (\(source)): \"\(snap.compositionName)\" deck \(snap.deckName), \(snap.layers.count) layers, \(snap.columns.count) columns")
        }
        subscribeNames(snap)
        if case .connected = status {
            publish(status: status)
        } else {
            Task { [client] in
                let st = await client.status()
                self.queue.async { self.publish(status: st) }
            }
        }
    }

    /// Delivers (snapshot, status, updatedAt) to `onChange` unless they equal the
    /// last delivery (`updatedAt` counts only outside live mode, where menus show it).
    private func publish(status st: ArenaStatus) {
        if st != status { log?.add("Status: \(st.plainLine)") }
        status = st
        let snap = snapshot, up = updatedAt
        if let d = delivered, d.status == st, d.snapshot == snap, mode == .live || d.updatedAt == up { return }
        delivered = (snap, st, up)
        deliveries += 1
        DispatchQueue.main.async { [weak self] in self?.onChange?(snap, st, up) }
    }
}
