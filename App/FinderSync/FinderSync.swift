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

import Cocoa
import FinderSync
import SendEhrKit
import SendEhrKitUI

/// Finder right-click > Send to Arena. The menu is built from the host app's
/// App Group cache only (menu(for:) is synchronous; never touches the
/// network). A pick is written as a LoadRequest and the host performs it.
final class FinderSync: FIFinderSync {
    private let shared = SharedStore.appGroupStore()
    private var renderer = SendMenuRenderer()
    private var menuURLs: [URL] = []
    /// The snapshot the menu was built from (new-layer picks send the indices it showed).
    private var menuSnapshot: CompositionSnapshot?

    override init() {
        super.init()
        updateDirectories()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    @objc private func volumesChanged(_ note: Notification) { updateDirectories() }

    /// "/" plus every mounted volume, so the menu appears everywhere.
    private func updateDirectories() {
        var urls: Set<URL> = [URL(fileURLWithPath: "/")]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        urls.formUnion(volumes)
        FIFinderSyncController.default().directoryURLs = urls
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        let sel = MediaSelection(urls)
        // No menu at all unless the selection holds a type Arena opens or a folder.
        guard !sel.files.isEmpty || !sel.folders.isEmpty else { return NSMenu(title: "") }

        let cache = shared?.readCache()
        let alive = shared?.hostIsAlive(cache) ?? false
        let settings = shared?.readSettings() ?? .default
        // Live: wake only while disconnected. On Demand / Interval: every open
        // (the host fetches; this menu shows the cache as it is now).
        if alive, settings.updateMode != .live || !(cache?.status.isConnected ?? false) {
            post(SharedStore.wakeNotification)
        }
        let input = SendMenuInput(snapshot: cache?.snapshot, status: cache?.status ?? .unknown, hostAlive: alive,
                                  recents: shared?.readRecents() ?? [], settings: settings,
                                  fileCount: sel.files.count, unsupportedCount: sel.unsupported,
                                  folderNames: sel.folders.map(\.lastPathComponent), updatedAt: cache?.updatedAt)
        let nodes: [MenuNode] = shared == nil ? [.info("SendEhr: App Group unavailable")] : SendMenuModel.build(input)

        renderer = SendMenuRenderer()
        menuURLs = sel.folders + sel.files
        menuSnapshot = cache?.snapshot
        let menu = NSMenu(title: "")
        menu.addItem(renderer.rootItem(nodes, target: self, action: #selector(pick(_:))))
        return menu
    }

    @objc func pick(_ sender: NSMenuItem) {
        guard let action = renderer.action(forTag: sender.tag) else { return }
        switch action {
        case .openHost:
            openHost()
        case .refresh:
            post(SharedStore.refreshNotification)
        case let .setting(change):
            submit(.settingChange(change))
        case let .load(destination, replace):
            let sel = MediaSelection(FIFinderSyncController.default().selectedItemURLs() ?? menuURLs)
            submit(LoadRequest(paths: (sel.folders + sel.files).map(\.path), destination: destination,
                               replaceConfirmed: replace, label: renderer.label(forTag: sender.tag) ?? sender.title,
                               expectedLayers: SendMenuModel.expectedLayers(destination, snap: menuSnapshot,
                                                                            folderCount: sel.folders.count)))
        }
    }

    private func submit(_ request: LoadRequest) {
        do {
            try shared?.submit(request)
            post(SharedStore.requestNotification)
        } catch {
            NSLog("SendEhr: could not submit request: \(error)")
        }
    }

    /// No userInfo: a sandboxed sender loses it.
    private func post(_ name: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name), object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// The host app contains this extension: .../SendEhr.app/Contents/PlugIns/X.appex
    private func openHost() {
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}
