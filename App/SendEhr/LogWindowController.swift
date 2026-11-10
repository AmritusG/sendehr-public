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

/// Last 500 events, live, with Copy All.
@MainActor final class LogWindowController: NSWindowController {
    private let log: EventLog
    private let textView: NSTextView

    init(log: EventLog) {
        self.log = log
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "SendEhr Log"
        window.isReleasedWhenClosed = false

        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        let copy = NSButton(title: "Copy All", target: nil, action: nil)
        let content = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        copy.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        content.addSubview(copy)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            copy.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            copy.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            copy.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        window.contentView = content
        window.center()
        super.init(window: window)
        copy.target = self
        copy.action = #selector(copyAll)
        reload()
        log.observe { [weak self] _ in DispatchQueue.main.async { self?.reload() } }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func reload() {
        textView.string = log.text
        textView.scrollToEndOfDocument(nil)
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(log.text, forType: .string)
    }
}
