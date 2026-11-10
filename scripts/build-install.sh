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
# Development install: Release build -> /Applications/SendEhr.app -> relaunch.
# Derived data stays inside this checkout (.dist/dd-dev, gitignored).
# Prints stale-process checks and the single pluginkit record.
set -euo pipefail
ROOT=${0:A:h:h}
DD=${SENDEHR_DD:-$ROOT/.dist/dd-dev}
cd "$ROOT/App"
xcodegen generate -q
xcodebuild -project SendEhr.xcodeproj -scheme SendEhr -configuration Release -derivedDataPath "$DD" build 2>&1 \
  | grep -E "error:|warning: .*\.swift|BUILD (SUCCEEDED|FAILED)" | grep -v appintents || true
APP="$DD/Build/Products/Release/SendEhr.app"
codesign --verify --deep --strict "$APP"
echo "before: pgrep -x SendEhr = '$(pgrep -x SendEhr || true)'"
pkill -x SendEhr || true
sleep 1
echo "killed: pgrep -x SendEhr = '$(pgrep -x SendEhr || true)'"
rm -rf /Applications/SendEhr.app
ditto "$APP" /Applications/SendEhr.app
# One registration only: Xcode registers the build-products copy too, and
# Finder may then load that extension instead of the one in /Applications.
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
pluginkit -r "$APP/Contents/PlugIns/SendEhrFinderSync.appex" 2>/dev/null || true
$LSREG -u "$APP" 2>/dev/null || true
pluginkit -a /Applications/SendEhr.app/Contents/PlugIns/SendEhrFinderSync.appex
# ignore -> use restarts the extension on the new binary (a plain kill leaves
# Finder without it until it is toggled).
pluginkit -e ignore -i com.amritus.sendehr.findersync
sleep 1
pluginkit -e use -i com.amritus.sendehr.findersync
open /Applications/SendEhr.app
sleep 3
echo "after:  pgrep -x SendEhr = '$(pgrep -x SendEhr || true)'"
# A first registration can come up without the user election ("use"): repeat it
# until pluginkit shows the extension enabled ("+"), or fail.
for i in 1 2 3 4 5; do
    pluginkit -m -A -D -v -i com.amritus.sendehr.findersync | grep -q '^+' && break
    pluginkit -e use -i com.amritus.sendehr.findersync
    sleep 2
done
pluginkit -m -A -D -v -i com.amritus.sendehr.findersync   # must list exactly one: /Applications, enabled (+)
pluginkit -m -A -D -v -i com.amritus.sendehr.findersync | grep -q '^+' || { echo "extension not enabled"; exit 1; }
