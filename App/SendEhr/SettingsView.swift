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

import SwiftUI
import SendEhrKit
import SendEhrKitUI

struct SettingsView: View {
    @ObservedObject var controller: SendToArenaController
    @State private var host = ""
    @State private var port = ""
    @State private var remaps: [PathRemap] = []
    @State private var mode: OccupiedSlotMode = .ask
    @State private var trigger = false
    @State private var scope: TriggerScope = .allNewLayers
    @State private var extra = 8
    @State private var sortKey: SortKey = .name
    @State private var ascending = true
    @State private var subfolders = false
    @State private var threshold = "50"
    @State private var updateMode: ArenaUpdateMode = .live
    @State private var updateInterval = 60

    var body: some View {
        Form {
            Section("Arena") {
                TextField("Host", text: $host)
                TextField("Port", text: $port)
                Text(controller.status.plainLine).font(.caption).foregroundStyle(.secondary)
                Picker("Arena updates", selection: $updateMode) {
                    Text("Live (websocket, every change pushed)").tag(ArenaUpdateMode.live)
                    Text("On Demand (fetch when a menu opens)").tag(ArenaUpdateMode.onDemand)
                    Text("Interval (fetch every few seconds)").tag(ArenaUpdateMode.interval)
                }
                Picker("Interval", selection: $updateInterval) {
                    ForEach(ArenaUpdateMode.intervals, id: \.self) { Text(ArenaUpdateMode.intervalTitle($0)).tag($0) }
                }
                .disabled(updateMode != .interval)
            }
            Section("Paths on the Arena machine (remote Arena only)") {
                ForEach($remaps) { $r in
                    HStack {
                        TextField("This Mac", text: $r.localPrefix)
                        Image(systemName: "arrow.right")
                        TextField("Arena machine", text: $r.remotePrefix)
                        Button(role: .destructive) { remaps.removeAll { $0.id == r.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Path Mapping") { remaps.append(PathRemap(localPrefix: "/Volumes/", remotePrefix: "/Volumes/")) }
            }
            Section("Loading") {
                Picker("Occupied slot", selection: $mode) {
                    Text("Ask before replacing").tag(OccupiedSlotMode.ask)
                    Text("Separate Replace item").tag(OccupiedSlotMode.replaceItem)
                }
                Toggle("Trigger after load", isOn: $trigger)
                Picker("Trigger scope (several new layers)", selection: $scope) {
                    ForEach(TriggerScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!trigger)
                Stepper("Empty columns shown past the last used: \(extra)", value: $extra, in: 0...50)
            }
            Section("Order and folders") {
                Picker("Sort by", selection: $sortKey) {
                    ForEach(SortKey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Direction", selection: $ascending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                Toggle("Include subfolders", isOn: $subfolders)
                TextField("Ask before loading more than (files)", text: $threshold)
            }
            HStack {
                Spacer()
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .onAppear { load() }
        // Settings also change from the Finder menu and the menu bar: show the
        // live values, so Apply never writes back a stale field.
        // (@Published emits before the property is set: use the emitted value.)
        .onReceive(controller.$settings) { load($0) }
    }

    private func load(_ new: SendEhrSettings? = nil) {
        let s = new ?? controller.settings
        host = s.endpoint.host
        port = String(s.endpoint.port)
        remaps = s.remaps
        mode = s.occupiedSlotMode
        trigger = s.triggerAfterLoad
        scope = s.triggerScope
        extra = s.extraEmptyColumns
        sortKey = s.sortKey
        ascending = s.sortAscending
        subfolders = s.includeSubfolders
        threshold = String(s.largeFolderThreshold)
        updateMode = s.updateMode
        updateInterval = s.updateInterval
    }

    private func apply() {
        var s = controller.settings
        let h = host.trimmingCharacters(in: .whitespaces)
        s.endpoint = ArenaEndpoint(host: h.isEmpty ? "localhost" : h, port: Int(port) ?? 8080)
        s.remaps = remaps.filter { !$0.localPrefix.isEmpty && !$0.remotePrefix.isEmpty }
        s.occupiedSlotMode = mode
        s.triggerAfterLoad = trigger
        s.triggerScope = scope
        s.extraEmptyColumns = extra
        s.sortKey = sortKey
        s.sortAscending = ascending
        s.includeSubfolders = subfolders
        s.largeFolderThreshold = max(1, Int(threshold.trimmingCharacters(in: .whitespaces)) ?? s.largeFolderThreshold)
        if s.updateMode != updateMode || s.updateInterval != updateInterval { s.updateModeChosen = true }
        s.updateMode = updateMode
        s.updateInterval = updateInterval
        controller.update(settings: s)
        controller.log.add("Settings window: Apply (\(s.logSummary))")
        load()
    }
}
