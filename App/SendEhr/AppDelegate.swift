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
import FinderSync
import ServiceManagement
import SwiftUI
import SendEhrKit
import SendEhrKitUI

@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        app.run()
    }

    private var controller: SendToArenaController!
    private var shared: SharedStore!
    private var statusItem: NSStatusItem!
    private var heartbeat: Timer?
    /// Cache encode + write run here, off the main thread (a 43 x 45 snapshot is ~290 KB of JSON).
    private let cacheQueue = DispatchQueue(label: "sendehr.cache", qos: .utility)
    private var queue: [LoadRequest] = []
    private var working = false
    private var settingsWindow: NSWindow?
    private var logWindow: LogWindowController?
    private var settingsRenderer = SendMenuRenderer()

    func applicationDidFinishLaunching(_ note: Notification) {
        let migrated = LegacyMigration.migrateAppGroup(home: FileManager.default.homeDirectoryForCurrentUser) {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
        guard let store = SharedStore.appGroupStore() else {
            let a = NSAlert()
            a.messageText = "SendEhr cannot open its App Group container"
            a.informativeText = "The app is not signed with the App Group entitlement (\(SharedStore.appGroup))."
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        shared = store
        controller = SendToArenaController(shared: store)
        controller.onStateChange = { [weak self] in self?.publishCache() }
        controller.log.mirror(to: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SendEhr/SendEhr.log"))
        controller.log.add("SendEhr \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "") launched, pid \(getpid())")
        if let migrated { controller.log.add(migrated) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "SendEhr")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(requestsArrived), name: Notification.Name(SharedStore.requestNotification), object: nil,
            suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(wakeRequested), name: Notification.Name(SharedStore.wakeNotification), object: nil,
            suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(refreshRequested), name: Notification.Name(SharedStore.refreshNotification), object: nil,
            suspensionBehavior: .deliverImmediately)

        controller.start()
        publishCache()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.touchCache() }
        }
        heartbeat?.tolerance = 2
        requestsArrived()   // anything submitted while we were not running
    }

    // MARK: cache for the Finder extension

    /// Called on every change of snapshot (play state included), status, settings or recents.
    private func publishCache() {
        guard let shared, let controller else { return }
        let state = CacheState(status: controller.status, snapshot: controller.snapshot, hostPID: getpid(),
                               updatedAt: controller.updatedAt)
        let log = controller.log
        cacheQueue.async {
            do { try shared.writeCache(state) } catch { log.add("cache write failed: \(error)") }
        }
        let disabled = !controller.status.isConnected
        if statusItem?.button?.appearsDisabled != disabled { statusItem?.button?.appearsDisabled = disabled }
    }

    /// Heartbeat for the extension's "host alive" check: mtime only, no re-encode.
    private func touchCache() {
        guard let shared else { return }
        cacheQueue.async { try? shared.touchCache() }
    }

    // MARK: requests from the Finder extension

    @objc private func wakeRequested() { controller.wake() }

    @objc private func refreshRequested() { controller.refresh() }

    @objc private func requestsArrived() {
        let taken = shared.takeRequests()
        guard !taken.isEmpty else { return }
        queue += taken
        runNext()
    }

    private func runNext() {
        guard !working, !queue.isEmpty else { return }
        let r = queue.removeFirst()
        if let change = r.setting {
            controller.apply(change)
            runNext()
            return
        }
        working = true
        controller.log.add("Finder request \(r.id.uuidString.prefix(8)): \(r.paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
        controller.load(paths: r.paths, to: r.destination, replaceConfirmed: r.replaceConfirmed, label: r.label,
                        expectedLayers: r.expectedLayers) { [weak self] _ in
            self?.working = false
            self?.runNext()
        }
    }

    // MARK: status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        controller.wake()
        let st = controller.status
        let head = NSMenuItem(title: (st.isConnected ? "\u{25CF} " : "\u{25CB} ") + st.plainLine, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        if let s = controller.snapshot, st.isConnected {
            let info = NSMenuItem(title: "Deck \u{201C}\(s.deckName)\u{201D} \u{00B7} \(s.compositionName) \u{00B7} \(s.layers.count) layers \u{00D7} \(s.columns.count) columns",
                                  action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        // On Demand / Interval: "Updated n s ago" + Refresh (this open's fetch shows at the next open).
        for node in SendMenuModel.freshnessNodes(SendMenuInput(snapshot: nil, status: st, settings: controller.settings,
                                                               fileCount: 0, updatedAt: controller.updatedAt)) {
            if case .action = node { add(menu, "Refresh", #selector(refreshPicked), "r") }
            else if let t = node.title { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        }
        if let last = controller.lastOutcome {
            let item = NSMenuItem(title: "Last: \(last)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        // Same items (and the same shared setting) as the Finder menu.
        settingsRenderer = SendMenuRenderer()
        let nodes = SendMenuModel.settingNodes(controller.settings, folders: true, triggerScope: true, updatesInline: true)
        for item in settingsRenderer.menu(title: "", nodes: nodes, target: self, action: #selector(pickSetting(_:))).items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
        add(menu, "Settings\u{2026}", #selector(showSettings), ",")
        add(menu, "Log\u{2026}", #selector(showLog), "l")
        add(menu, "Finder Extension\u{2026}", #selector(showExtensions), "")
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        menu.addItem(login)
        menu.addItem(.separator())
        add(menu, "Quit SendEhr", #selector(quit), "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func refreshPicked() { controller.refresh() }

    @objc private func pickSetting(_ sender: NSMenuItem) {
        guard case let .setting(change)? = settingsRenderer.action(forTag: sender.tag) else { return }
        controller.apply(change)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { controller.log.add("Open at Login: \(error.localizedDescription)") }
    }

    @objc private func showExtensions() { FIFinderSyncController.showExtensionManagementInterface() }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "SendEhr Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(controller: controller))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showLog() {
        if logWindow == nil { logWindow = LogWindowController(log: controller.log) }
        NSApp.activate(ignoringOtherApps: true)
        logWindow?.showWindow(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
