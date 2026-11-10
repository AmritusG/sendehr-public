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

/// Renders `MenuNode`s as an NSMenu. Finder Sync rebuilds the menu inside
/// Finder and keeps title / tag / action / submenu / state (checkmarks: Finder's
/// AXMenuItemMarkChar reads ✓), so every action is carried by
/// its `tag`; look it up with `action(forTag:)` in the handler.
public final class SendMenuRenderer {
    public private(set) var actions: [Int: MenuAction] = [:]
    public private(set) var labels: [Int: String] = [:]
    private var nextTag = 1

    public init() {}

    public func action(forTag tag: Int) -> MenuAction? { actions[tag] }
    public func label(forTag tag: Int) -> String? { labels[tag] }

    /// The top-level "Send to Arena" item with its submenu.
    public func rootItem(_ nodes: [MenuNode], title: String = SendMenuModel.rootTitle,
                         target: AnyObject?, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu(title: title, nodes: nodes, target: target, action: action)
        return item
    }

    public func menu(title: String, nodes: [MenuNode], target: AnyObject?, action: Selector) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        for node in nodes {
            switch node {
            case .separator:
                menu.addItem(.separator())
            case let .info(text):
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case let .submenu(t, children):
                let item = NSMenuItem(title: t, action: nil, keyEquivalent: "")
                item.submenu = self.menu(title: t, nodes: children, target: target, action: action)
                menu.addItem(item)
            case let .action(t, a, label):
                menu.addItem(actionItem(t, a, label: label, target: target, action: action))
            case let .toggle(t, isOn, a):
                let item = actionItem(t, a, label: t, target: target, action: action)
                item.state = isOn ? .on : .off
                menu.addItem(item)
            }
        }
        return menu
    }

    private func actionItem(_ title: String, _ a: MenuAction, label: String, target: AnyObject?, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.tag = nextTag
        item.isEnabled = true
        actions[nextTag] = a
        labels[nextTag] = label
        nextTag += 1
        return item
    }
}
