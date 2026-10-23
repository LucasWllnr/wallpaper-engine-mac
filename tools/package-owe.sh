#!/bin/zsh
# Version distribuable d'Open Wallpaper Engine : l'app + le moteur de scènes (linux-wallpaperengine),
# CEF et toutes les bibliothèques Homebrew dans le bundle, signée ad hoc, dans une image disque.
# Usage : zsh tools/package-owe.sh            (OWE_SRC=<dossier source> pour un worktree)
# Résultat : <source>/build/Open-Wallpaper-Engine-<version>.dmg (Apple Silicon, macOS 14+)
set -euo pipefail
ROOT="${0:A:h:h}"
SRC="${OWE_SRC:-$ROOT/app}"
OUT="$SRC/build"
APP="$OUT/Open Wallpaper Engine.app"
ENGINE="$ROOT/engine/linux-wallpaperengine/build"

zsh "$ROOT/tools/build-owe.sh"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

echo "==> Moteur de scènes et CEF"
FW="$APP/Contents/Frameworks"
mkdir -p "$FW"
cp "$ENGINE/output/linux-wallpaperengine" "$APP/Contents/MacOS/"
# le moteur charge CEF depuis @executable_path/../Frameworks : Contents/Frameworks
ditto "$(readlink -f "$ENGINE/Frameworks/Chromium Embedded Framework.framework")" "$FW/Chromium Embedded Framework.framework"

echo "==> Bibliothèques"
python3 -I "$ROOT/tools/bundle-dylibs.py" "$FW" "$APP/Contents/MacOS/linux-wallpaperengine" \
    --search "$ENGINE/output" --search "$ENGINE/lib" --search /opt/homebrew/lib
# pas de minimum macOS plus bas que celui du moteur (std::format)
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 14.0" "$APP/Contents/Info.plist"

echo "==> Signature (de l'intérieur vers l'extérieur)"
find "$FW" -maxdepth 1 -name "*.dylib" -exec codesign --force --sign - {} \;
codesign --force --sign - "$FW/Chromium Embedded Framework.framework"
codesign --force --sign - "$APP/Contents/MacOS/linux-wallpaperengine"
codesign --force --sign - "$APP/Contents/Resources/wehelper-mac" "$APP/Contents/Resources/libsteam_api.dylib"
codesign --force --sign - --entitlements "$OUT/app.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Vérification : aucun chemin vers Homebrew ni vers cette machine"
if find "$APP/Contents" -type f \( -perm -u+x -o -name "*.dylib" \) -print0 | xargs -0 otool -L 2>/dev/null \
        | grep -E "^\s+(/opt/homebrew|/usr/local|$HOME)"; then
    echo "ERREUR : dépendances hors du bundle" >&2; exit 1
fi
# le moteur ne quitte pas seul : on le lance 3 s, le temps que dyld charge tout
LOADED="$OUT/engine-libraries.log"
DYLD_PRINT_LIBRARIES=1 "$APP/Contents/MacOS/linux-wallpaperengine" --help >/dev/null 2>"$LOADED" & PID=$!
sleep 3; kill -9 $PID 2>/dev/null || true
grep -q "Chromium Embedded Framework" "$LOADED" || { echo "ERREUR : le moteur n'a pas démarré" >&2; exit 1; }
grep -E "/opt/homebrew|$ROOT/engine" "$LOADED" && { echo "ERREUR : le moteur charge des fichiers hors du bundle" >&2; exit 1; }
echo "    $(grep -c "$APP" "$LOADED") bibliothèques chargées depuis l'app"

echo "==> Image disque"
STAGE="$OUT/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Open Wallpaper Engine.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/tools/dmg-readme.txt" "$STAGE/Lisez-moi - Read me.txt"
DMG="$OUT/Open-Wallpaper-Engine-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Open Wallpaper Engine" -srcfolder "$STAGE" -fs HFS+ -format ULFO "$DMG" >/dev/null
rm -rf "$STAGE"
du -h "$DMG"
echo "==> Prêt : $DMG"
