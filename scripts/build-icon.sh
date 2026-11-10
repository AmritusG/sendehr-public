#!/bin/zsh
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
# Renders the artwork from its SVG masters in App/Art:
#   App/Art/SendEhr-icon.svg   -> App/SendEhr/SendEhr.icns (16-1024 px, iconutil)
#   App/Art/dmg-background.svg -> App/Art/dmg-background.png (660 x 495)
#                                 + dmg-background@2x.png (1320 x 990)
# The outputs are committed, so building the app needs neither tool; run this
# after editing a master. Requires rsvg-convert (brew install librsvg) and
# iconutil (Xcode command line tools).
set -euo pipefail
ROOT=${0:A:h:h}
ART="$ROOT/App/Art"
ICNS="$ROOT/App/SendEhr/SendEhr.icns"
command -v rsvg-convert >/dev/null || { echo "rsvg-convert missing: brew install librsvg"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SET="$WORK/SendEhr.iconset"
mkdir -p "$SET"
for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x \
            256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
    rsvg-convert -w ${spec%%:*} -h ${spec%%:*} "$ART/SendEhr-icon.svg" -o "$SET/icon_${spec#*:}.png"
done
iconutil -c icns "$SET" -o "$ICNS"
rsvg-convert -w 660 -h 495 "$ART/dmg-background.svg" -o "$ART/dmg-background.png"
rsvg-convert -w 1320 -h 990 "$ART/dmg-background.svg" -o "$ART/dmg-background@2x.png"
ls -l "$ICNS" "$ART"/dmg-background*.png
