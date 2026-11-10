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
# Distribution build of SendEhr: Release build (stripped, dSYMs kept aside)
# -> check that no binary holds a build-machine path -> verify signature ->
# notarise the app -> staple -> styled DMG (app + /Applications link, window
# layout and background via dmgbuild) -> sign DMG ->
# notarise the DMG -> staple -> verify -> SHA-256.
#
#   scripts/release.sh            run from a clean checkout whose HEAD is tagged v<version>
#   ALLOW_DIRTY=1 scripts/release.sh   skip the clean-tree / tag check (test runs only)
#
# Everything is written inside this checkout under .dist/release (gitignored):
#   dd/                 Xcode derived data
#   SendEhr.app         the stapled app
#   SendEhr-<v>.dmg     the stapled DMG, plus .sha256
#   dSYM/               the dSYMs of the shipped binaries (not shipped; keep them
#                       to symbolicate crash reports: same build UUID)
#   notary-*.json       notarytool submit results and logs
# and ../venv-dmg (dmgbuild, installed once from scripts/dmg-requirements.txt,
# pinned by hash).
#
# Requirements: Xcode, xcodegen, Python 3.10+ (for dmgbuild), a "Developer ID
# Application" identity for the team in App/project.yml, and notarytool credentials stored in the keychain
# (xcrun notarytool store-credentials <profile>); the profile name comes from
# NOTARY_PROFILE (default amritus-notary). No secret is read or printed here.
# Steps follow Apple's "Notarizing macOS software before distribution",
# "Customizing the notarization workflow" and "Packaging Mac software for
# distribution".
set -euo pipefail
ROOT=${0:A:h:h}
PROFILE=${NOTARY_PROFILE:-amritus-notary}
OUT="$ROOT/.dist/release"
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
VERSION=$(awk '/MARKETING_VERSION:/ {print $2}' "$ROOT/App/project.yml")
[[ -n "$VERSION" ]] || { echo "MARKETING_VERSION not found in App/project.yml"; exit 1; }

cd "$ROOT"
if [[ -z "${ALLOW_DIRTY:-}" ]]; then
    [[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean"; exit 1; }
    git tag --points-at HEAD | grep -qx "v$VERSION" || { echo "HEAD is not tagged v$VERSION"; exit 1; }
fi
echo "==> SendEhr $VERSION from $(git rev-parse --short HEAD)"

rm -rf "$OUT"
mkdir -p "$OUT"
DD="$OUT/dd"
APP="$OUT/SendEhr.app"
DMG="$OUT/SendEhr-$VERSION.dmg"

# Unregister a built copy so the only SendEhr Finder extension LaunchServices
# knows stays the one in /Applications (building and spctl register copies).
unregister() {
    pluginkit -r "$1/Contents/PlugIns/SendEhrFinderSync.appex" 2>/dev/null || true
    $LSREG -u "$1" 2>/dev/null || true
}

# Submit one file, wait, save the result and the developer log, require Accepted.
notarise() {
    local file=$1 tag=$2 id rc result
    xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait \
        --output-format json > "$OUT/notary-$tag-submit.json" && rc=0 || rc=$?
    id=$(plutil -extract id raw -o - "$OUT/notary-$tag-submit.json" 2>/dev/null || true)
    result=$(plutil -extract status raw -o - "$OUT/notary-$tag-submit.json" 2>/dev/null || true)
    echo "    $tag: id $id, status $result"
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" "$OUT/notary-$tag-log.json" >/dev/null
    [[ $rc -eq 0 && "$result" == "Accepted" ]] || { echo "notarisation of $tag failed (see $OUT)"; exit 1; }
}

echo "==> Build (Release)"
cd "$ROOT/App"
xcodegen generate -q
# Release strips the app and the extension (App/project.yml, configs: Release);
# the check below fails the release if a build-machine path is left.
xcodebuild -project SendEhr.xcodeproj -scheme SendEhr -configuration Release \
    -derivedDataPath "$DD" clean build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
PRODUCTS="$DD/Build/Products/Release"
BUILT="$PRODUCTS/SendEhr.app"
[[ -d "$BUILT" ]] || { echo "build failed"; exit 1; }
cd "$ROOT"
ditto "$BUILT" "$APP"
unregister "$BUILT"
mkdir -p "$OUT/dSYM"
ditto "$PRODUCTS/SendEhr.app.dSYM" "$OUT/dSYM/SendEhr.app.dSYM"
ditto "$PRODUCTS/SendEhrFinderSync.appex.dSYM" "$OUT/dSYM/SendEhrFinderSync.appex.dSYM"

echo "==> Build-machine path check"
# Every Mach-O in the app: no absolute build path, no user or home name, no
# build folder (grep -a reads the raw bytes, strings(1) misses some).
FORBIDDEN=(/Users/ /private/ /var/folders/ /tmp/ .build/ .dist/ DerivedData "$USER" "$ROOT")
DSYM_UUIDS=$(dwarfdump --uuid "$OUT"/dSYM/*.dSYM | awk '{print $2}')
machos=0
while IFS= read -r -d '' f; do
    file -b "$f" | grep -q "Mach-O" || continue
    machos=$((machos + 1))
    for p in $FORBIDDEN; do
        if LC_ALL=C grep -a -q -F -- "$p" "$f"; then echo "found '$p' in ${f#$APP/}"; exit 1; fi
    done
    dwarfdump --uuid "$f" | awk '{print $2}' | while read -r uuid; do
        print -r -- "$DSYM_UUIDS" | grep -qx "$uuid" || { echo "no dSYM for $uuid (${f#$APP/})"; exit 1; }
    done
done < <(find "$APP" -type f -print0)
(( machos > 0 )) || { echo "no Mach-O found"; exit 1; }
echo "    $machos Mach-O files clean, dSYM UUIDs match"

echo "==> Signature checks"
codesign --verify --deep --strict --verbose=2 "$APP"
for code in "$APP" "$APP/Contents/PlugIns/SendEhrFinderSync.appex"; do
    info=$(codesign -dvv "$code" 2>&1)
    print -r -- "$info" | grep -q "flags=.*runtime" || { echo "no hardened runtime: $code"; exit 1; }
    print -r -- "$info" | grep -q "^Timestamp=" || { echo "no secure timestamp: $code"; exit 1; }
    print -r -- "$info" | grep -q "^Authority=Developer ID Application" || { echo "not Developer ID: $code"; exit 1; }
    if codesign -d --entitlements - --xml "$code" 2>/dev/null | grep -q "get-task-allow"; then
        echo "get-task-allow present: $code"; exit 1
    fi
done

echo "==> Notarise the app"
ditto -c -k --keepParent "$APP" "$OUT/SendEhr-app.zip"
notarise "$OUT/SendEhr-app.zip" app
rm -f "$OUT/SendEhr-app.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> DMG"
VENV="$ROOT/.dist/venv-dmg"
if [[ ! -x "$VENV/bin/dmgbuild" ]]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --require-hashes -r "$ROOT/scripts/dmg-requirements.txt"
fi
"$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg-settings.py" -D app="$APP" -D art="$ROOT/App/Art" \
    "SendEhr $VERSION" "$DMG"
codesign -s "Developer ID Application" --timestamp -i com.amritus.sendehr.dmg "$DMG"

echo "==> Notarise the DMG"
notarise "$DMG" dmg
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Gatekeeper"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
unregister "$APP"

(cd "$OUT" && shasum -a 256 "${DMG:t}" | tee "${DMG:t}.sha256")
ls -la "$OUT"
echo "==> Done: $DMG"
