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

import AppKit
import SendEhrKit

/// One-call "Send to Arena" for an app: keeps a live composition, builds the
/// menu, performs loads (asking before overwriting occupied slots) and keeps
/// recents + a 500-line log. SendEhr.app and MaCrate both use it.
@MainActor
public final class SendToArenaController: ObservableObject {
    /// Default instance storing settings under ~/Library/Application Support/SendEhrKit/<bundle id>.
    public static let shared: SendToArenaController = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appendingPathComponent(SharedStore.kitFolder, isDirectory: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "app", isDirectory: true)
        return SendToArenaController(shared: SharedStore(root: root))
    }()

    nonisolated public static let arenaBundleID = "com.resolume.arena"

    /// Latest composition. Not `@Published`: views redraw (one `objectWillChange`)
    /// only when the menu layout or the status changes; a play-state-only change
    /// (the menu's play mark) updates the value and `onStateChange` silently.
    public private(set) var snapshot: CompositionSnapshot?
    public private(set) var status: ArenaStatus = .unknown
    /// When the composition last arrived (On Demand / Interval menus show "Updated n s ago").
    public private(set) var updatedAt: Date?
    @Published public private(set) var settings: SendEhrSettings
    @Published public private(set) var recents: [RecentTarget]
    @Published public private(set) var busy = false
    @Published public private(set) var lastOutcome: String?

    public let log = EventLog()
    public let shared: SharedStore
    public private(set) var store: CompositionStore
    /// Called after each change of snapshot (play state included), status,
    /// settings or recents (the host writes its App Group cache here).
    public var onStateChange: (() -> Void)?
    /// Number of `objectWillChange` sends caused by the store (tests, diagnostics).
    public private(set) var redraws = 0
    private var started = false
    private var workspaceObservers: [NSObjectProtocol] = []

    public init(shared: SharedStore) {
        self.shared = shared
        let s = shared.readSettings()
        self.settings = s
        self.recents = shared.readRecents()
        self.store = CompositionStore(client: Self.makeClient(s.endpoint), mode: s.updateMode,
                                      interval: TimeInterval(s.updateInterval))
        store.log = log
        store.onChange = { [weak self] snap, st, up in
            self?.receive(snap, st, updatedAt: up)
        }
    }

    /// `updatedAt` alone never redraws: an open menu re-running `nodes(for:)`
    /// would fetch again (On Demand) and loop.
    func receive(_ snap: CompositionSnapshot?, _ st: ArenaStatus, updatedAt up: Date? = nil) {
        if st != status || !CompositionSnapshot.sameMenu(snapshot, snap) {
            redraws += 1
            objectWillChange.send()
        }
        snapshot = snap
        status = st
        updatedAt = up
        onStateChange?()
    }

    nonisolated static func makeClient(_ endpoint: ArenaEndpoint) -> ArenaClient {
        ArenaClient(endpoint: endpoint) {
            !NSRunningApplication.runningApplications(withBundleIdentifier: arenaBundleID).isEmpty
        }
    }

    public var client: ArenaClient { Self.makeClient(settings.endpoint) }

    /// Starts the updates (Live: websocket + poll; On Demand / Interval: REST fetches). Safe to call repeatedly.
    /// `defaultUpdateMode`: this host's mode until the user picks one in a menu
    /// (`updateModeChosen`); a pick always wins and is remembered. Call it once
    /// at launch: the menu's own auto-start uses `.live`.
    public func start(defaultUpdateMode: ArenaUpdateMode = .live) {
        guard !started else { return }
        started = true
        if !settings.updateModeChosen, settings.updateMode != defaultUpdateMode {
            log.add("Arena Updates: host default \(defaultUpdateMode.title) (no user pick; file said \(settings.updateDescription))")
            settings.updateMode = defaultUpdateMode
            try? shared.writeSettings(settings)
            store.setMode(defaultUpdateMode, interval: TimeInterval(settings.updateInterval))   // before store.start: same serial queue
        }
        log.add("SendEhrKit start: \(settings.endpoint.host):\(settings.endpoint.port), Arena Updates \(settings.updateDescription)")
        observeArenaLaunch()
        store.start()
    }

    /// Arena's launch / quit on this Mac drive the reconnect (no polling while it is absent).
    /// Apple: posted on NSWorkspace.shared.notificationCenter, userInfo applicationUserInfoKey
    /// = NSRunningApplication; not posted for LSUIElement apps (Arena is a regular app).
    private func observeArenaLaunch() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard Self.isArena(note) else { return }
                MainActor.assumeIsolated { self?.store.arenaLaunched() }
            },
            nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard Self.isArena(note) else { return }
                MainActor.assumeIsolated { self?.store.arenaTerminated() }
            },
        ]
    }

    nonisolated static func isArena(_ note: Notification) -> Bool {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == arenaBundleID
    }

    /// A menu is about to show. Live: if disconnected, try to connect now.
    /// On Demand / Interval: fetch (throttled by the store's `menuFetchGap`).
    public func wake() {
        if settings.updateMode != .live || !status.isConnected { store.wake() }
    }

    /// Fetch the composition now (the Refresh item).
    public func refresh() {
        log.add("Refresh")
        store.refresh(reason: "Refresh")
    }

    public func update(settings new: SendEhrSettings) {
        let endpointChanged = new.endpoint != settings.endpoint
        let updatesChanged = new.updateMode != settings.updateMode || new.updateInterval != settings.updateInterval
        settings = new
        try? shared.writeSettings(new)
        if endpointChanged {
            log.add("Endpoint -> \(new.endpoint.host):\(new.endpoint.port)")
            store.setClient(Self.makeClient(new.endpoint))
        }
        if updatesChanged {
            store.setMode(new.updateMode, interval: TimeInterval(new.updateInterval))
        }
        onStateChange?()
    }

    public func menuInput(urls: [URL]) -> SendMenuInput {
        let sel = MediaSelection(urls)
        return SendMenuInput(snapshot: snapshot, status: status, recents: recents, settings: settings,
                             fileCount: sel.files.count, unsupportedCount: sel.unsupported,
                             folderNames: sel.folders.map(\.lastPathComponent), updatedAt: updatedAt)
    }

    public func nodes(for urls: [URL]) -> [MenuNode] {
        if !started { start() } else { wake() }
        return SendMenuModel.build(menuInput(urls: urls))
    }

    public func perform(_ action: MenuAction, label: String, urls: [URL]) {
        switch action {
        case let .load(destination, replace):
            let sel = MediaSelection(urls)
            load(paths: (sel.folders + sel.files).map(\.path), to: destination, replaceConfirmed: replace, label: label,
                 expectedLayers: SendMenuModel.expectedLayers(destination, snap: snapshot, folderCount: sel.folders.count))
        case let .setting(change):
            apply(change)
        case .refresh:
            refresh()
        case .openHost:
            break
        }
    }

    /// One menu-picked setting (shared by the Finder menu, the menu bar and MaCrate).
    public func apply(_ change: SettingChange) {
        log.add("Setting: \(change.logLine)")
        update(settings: change.applied(to: settings))
    }

    /// Runs one load; result goes to the log and `lastOutcome`. `paths` may
    /// hold files and folders: folders expand (Include Subfolders), everything
    /// is ordered by the sort setting, and a large expansion is confirmed once.
    /// `expectedLayers`: the new-layer indices the menu showed (a mismatch is logged).
    public func load(paths: [String], to destination: Destination, replaceConfirmed: Bool, label: String,
                     expectedLayers: ClosedRange<Int>? = nil,
                     completion: ((Result<LoadOutcome, ArenaError>) -> Void)? = nil) {
        let loader = ArenaLoader(client: client, remaps: settings.remaps, log: log)
        let s = settings
        log.add("Request: \(paths.count) item(s) -> \(label)\(replaceConfirmed ? " (Replace)" : ""), \(s.logSummary)"
                + (expectedLayers.map { ", menu showed \(SendMenuModel.layersText($0))" } ?? ""))
        busy = true
        Task { @MainActor in
            defer { self.busy = false }
            do {
                let collection = await Task.detached {
                    MediaCollector.collect(paths: paths, includeSubfolders: s.includeSubfolders,
                                           sortKey: s.sortKey, ascending: s.sortAscending)
                }.value
                if !collection.folders.isEmpty || collection.skippedNonMedia > 0 {
                    self.log.add("Expanded: \(collection.summary)")
                }
                let perFolder = destination == .layerPerFolder
                let count = perFolder ? collection.fromFolders : collection.files.count
                if collection.needsConfirmation(threshold: s.largeFolderThreshold, foldersOnly: perFolder) {
                    let yes = Self.askLargeLoad(collection, count: count, perFolder: perFolder)
                    self.log.add("Large folder (\(count) files) -> \(yes ? "load" : "cancel")")
                    if !yes { throw ArenaError.cancelled }
                }
                if perFolder {
                    if collection.looseFiles > 0 {
                        self.log.add("Folders as New Layers: ignored \(collection.looseFiles) loose file(s) (not in a selected folder)")
                    }
                    let outcome = try await loader.loadLayers(groups: collection.groups, trigger: s.triggerAfterLoad,
                                                              scope: s.triggerScope, expectedLayers: expectedLayers)
                    self.lastOutcome = outcome.summary
                    self.log.add(outcome.summary)
                    self.store.refresh(reason: "after load")
                    completion?(.success(outcome.layers[0]))   // top-most layer; planLayers never returns zero layers
                    return
                }
                let outcome = try await loader.load(paths: collection.files, to: destination, trigger: s.triggerAfterLoad,
                                                    replaceConfirmed: replaceConfirmed, expectedLayers: expectedLayers) { conflicts in
                    await Self.askReplace(conflicts)
                }
                self.lastOutcome = outcome.summary
                self.log.add(outcome.summary)
                self.remember(destination, label: label)
                self.store.refresh(reason: "after load")
                completion?(.success(outcome))
            } catch let e as ArenaError {
                self.lastOutcome = e.plainLine
                self.log.add(e == .cancelled ? "Cancelled - nothing loaded" : "Load failed: \(e.plainLine)")
                if e != .cancelled { Self.showError(e) }
                completion?(.failure(e))
            } catch {
                self.log.add("Load failed: \(error)")
                completion?(.failure(.badResponse(error.localizedDescription)))
            }
        }
    }

    func remember(_ destination: Destination, label: String) {
        recents = RecentTarget.pushing(RecentTarget(destination: destination, label: label), onto: recents)
        try? shared.writeRecents(recents)
        onStateChange?()
    }

    /// Test hook / non-interactive mode: when set, used instead of the dialog.
    public static var replaceAnswerOverride: ConflictResolution?

    @MainActor
    static func askReplace(_ conflicts: [Assignment]) -> ConflictResolution {
        if let forced = replaceAnswerOverride { return forced }
        let alert = NSAlert()
        alert.messageText = conflicts.count == 1
            ? "Replace the clip in column \(conflicts[0].column)?"
            : "Replace \(conflicts.count) occupied slots?"
        alert.informativeText = conflicts.prefix(8).map {
            "Column \($0.column): \u{201C}\($0.replacing ?? "")\u{201D} \u{2192} \(($0.path as NSString).lastPathComponent)"
        }.joined(separator: "\n") + (conflicts.count > 8 ? "\n..." : "")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip Occupied")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .skip
        default: return .cancel
        }
    }

    /// Test hook: when set, used instead of the large-folder dialog.
    public static var largeLoadAnswerOverride: Bool?

    @MainActor
    static func askLargeLoad(_ c: MediaCollection, count: Int, perFolder: Bool) -> Bool {
        if let forced = largeLoadAnswerOverride { return forced }
        let alert = NSAlert()
        let names = c.folders.map { "\u{201C}\(($0 as NSString).lastPathComponent)\u{201D}" }.joined(separator: ", ")
        alert.messageText = "Load \(count) files?"
        alert.informativeText = "\(names): \(c.summary). "
            + (perFolder ? "One new layer per folder, each from column 1." : "They fill consecutive columns.")
        alert.addButton(withTitle: "Load \(count) Files")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Set false to log errors without a dialog (tests).
    public static var showsErrorAlerts = true

    static func showError(_ e: ArenaError) {
        guard showsErrorAlerts else { return }
        let alert = NSAlert()
        alert.messageText = "Send to Arena failed"
        alert.informativeText = e.plainLine
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

