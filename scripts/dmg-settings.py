# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Amrit Rosell
#
# This file is part of SendEhr.
#
# SendEhr is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version.
#
# SendEhr is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
# details.
#
# You should have received a copy of the GNU General Public License along
# with SendEhr.  If not, see <https://www.gnu.org/licenses/>.
#
# dmgbuild settings for the SendEhr installer window (scripts/release.sh):
# 660 x 495 pt (macOS 27 Finder: 68 pt title bar + 400 pt content + 27 pt
# bottom bar), icons 128 pt, app left, Applications link right, background
# App/Art/dmg-background.png (+ @2x, combined into one HiDPI TIFF by dmgbuild).
# dmgbuild writes the window layout into the volume's .DS_Store itself, so no
# Finder scripting is involved. Defines: app=<path to SendEhr.app>, art=<App/Art>.
import os

app = defines["app"]
art = defines["art"]

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
background = os.path.join(art, "dmg-background.png")
window_rect = ((200, 120), (660, 495))
default_view = "icon-view"
icon_size = 128
text_size = 13
icon_locations = {
    os.path.basename(app): (170, 190),
    "Applications": (490, 190),
}
