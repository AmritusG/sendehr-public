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

/// SwiftUI rendering of the same menu, for `.contextMenu { }` hosts (MaCrate).
///
///     .contextMenu {
///         SendToArenaMenu(controller: .shared, urls: resolveActionURLs(clip.url))
///     }
public struct SendToArenaMenu: View {
    @ObservedObject var controller: SendToArenaController
    let urls: [URL]

    public init(controller: SendToArenaController, urls: [URL]) {
        self.controller = controller
        self.urls = urls
    }

    public var body: some View {
        Menu(SendMenuModel.rootTitle) {
            MenuNodesView(nodes: controller.nodes(for: urls)) { action, label in
                controller.perform(action, label: label, urls: urls)
            }
        }
    }
}

struct MenuNodesView: View {
    let nodes: [MenuNode]
    let perform: (MenuAction, String) -> Void

    var body: some View {
        ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
            row(node)
        }
    }

    func row(_ node: MenuNode) -> AnyView {
        switch node {
        case .separator:
            return AnyView(Divider())
        case let .info(text):
            return AnyView(Text(text).foregroundStyle(.secondary))
        case let .submenu(title, children):
            return AnyView(Menu(title) { MenuNodesView(nodes: children, perform: perform) })
        case let .action(title, action, label):
            return AnyView(Button(title) { perform(action, label) })
        case let .toggle(title, isOn, action):
            return AnyView(Toggle(title, isOn: Binding(get: { isOn }, set: { _ in perform(action, title) })))
        }
    }
}
