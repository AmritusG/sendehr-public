# SendEhr

Right-click media files or folders in Finder and choose **Send to Arena > Layer > Column** to load them straight into Resolume Arena's clip grid. SendEhr is a small menu bar app plus a Finder extension. It talks to Arena through Arena's own webserver (REST API).

Not affiliated with or endorsed by Resolume. "Resolume" and "Arena" are named only to describe compatibility.

## Requirements

- A Mac with Apple silicon, macOS 14 or later (the app is built for arm64 only).
- Resolume Arena with its webserver turned on: Arena > Preferences > Webserver, enable the webserver / REST API. SendEhr uses `localhost`, port 8080, by default (change it under SendEhr > Settings… if Arena runs on another port or on another Mac).

## Install

1. Download `SendEhr-<version>.dmg` from the [releases page](https://github.com/AmritusG/sendehr-releases/releases). The app is signed with a Developer ID and notarised by Apple.
2. Open the DMG and drag **SendEhr** onto **Applications**.
3. Open SendEhr from Applications. macOS asks once whether to open an app downloaded from the internet: choose Open. A menu bar icon appears; SendEhr has no Dock icon.
4. Turn on the Finder extension: SendEhr menu bar icon > **Finder Extension…**, or System Settings > General > Login Items & Extensions, then under Extensions click the Info button next to SendEhr (or next to the Finder category), turn SendEhr on, then click Done.
5. Optional: SendEhr menu bar icon > **Open at Login**.

## Use

Select media files or folders in Finder, right-click, then **Send to Arena**:

- **Layer > Column** loads the selection into that slot and the next columns. Columns are added at the end when needed.
- **New Layer** adds a layer on top. **Folder as New Layer** / **Folders as New Layers** give each selected folder its own layer, named after the folder.
- Occupied slots are never overwritten silently: SendEhr asks first, or shows a separate Replace item (Settings).
- **Sort By**, **Include Subfolders** and **Trigger After Load** are in the same menu.

Supported files are the clip types Arena opens: video `mov mp4 avi mpg mpeg gif wmv` (including DXV and HAP inside `.mov`), images `png jpg jpeg tif tiff psd exr`, audio `wav aiff aif flac ogg`.

### Arena Updates

How the menu learns about Arena's layers and clips (menu > Arena Updates, or Settings):

- **Live** (default): a websocket to Arena; every change Arena pushes is reflected at once. Arena sends its whole composition with each push, so this costs some CPU while Arena changes often (for example while autopilot runs).
- **On Demand**: no connection in between; the composition is fetched when you open a menu. The menu shows "Updated n s ago" and a Refresh item.
- **Interval**: fetched every 15 s to 5 min, and when a menu opens.

Loads always re-read Arena's current state first, whichever mode is chosen.

### Arena on another Mac

Set the host and port in Settings. If the media lives at a different path on the Arena machine, add a path remap (this Mac's prefix -> the Arena machine's prefix).

## Build from source

Requirements: Xcode 15 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
scripts/build-install.sh   # Release build, installs /Applications/SendEhr.app, enables the extension
```

The project signs with the Developer ID team in `App/project.yml` and an App Group prefixed with that team id (`App/*/…entitlements`, `Sources/SendEhrKit/SharedStore.swift`). To build under your own team, change `DEVELOPMENT_TEAM`, the bundle ids and the App Group in those three places. Build output stays inside the checkout under `.dist/` (gitignored).

`scripts/release.sh` makes the distribution DMG: Release build, signature checks, notarisation of the app, stapling, DMG, notarisation of the DMG, stapling, Gatekeeper checks. It needs notarytool credentials in the keychain (`xcrun notarytool store-credentials <profile>`, profile name in `NOTARY_PROFILE`).

### SendEhrKit

The Arena logic is the Swift package **SendEhrKit** in this repository (products `SendEhrKit`, Foundation only, and `SendEhrKitUI`, AppKit/SwiftUI menus), usable from other apps:

```swift
.package(url: "https://github.com/AmritusG/sendehr-public.git", exact: "1.1.1")
// SwiftUI: SendToArenaMenu(controller: .shared, urls: selectedURLs)
```

## Licence

Copyright (C) 2026 Amrit Rosell.

SendEhr is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. It is distributed WITHOUT ANY WARRANTY. See [LICENSE](LICENSE) for the full text. SPDX: `GPL-3.0-or-later`.
