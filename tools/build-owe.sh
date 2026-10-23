#!/bin/zsh
# Construit Open Wallpaper Engine avec swiftc (sans projet Xcode : tous les .swift sont pris).
# Usage : zsh tools/build-owe.sh [--install]     (OWE_SRC=<dossier source> pour un worktree)
set -euo pipefail

ROOT="${0:A:h:h}"
SRC="${OWE_SRC:-$ROOT/app}"
APPSRC="$SRC/Open Wallpaper Engine"
OUT="$SRC/build"
APP="$OUT/Open Wallpaper Engine.app"

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compilation Swift"
find "$APPSRC" -name "*.swift" -not -path "*/Preview Content/*" -print0 \
    | xargs -0 swiftc -module-name Open_Wallpaper_Engine -target arm64-apple-macos13.0 -O \
        -o "$APP/Contents/MacOS/Open Wallpaper Engine"

echo "==> Ressources"
R="$APP/Contents/Resources"
cp "$APPSRC/Resources/WallpaperNotFound.mp4" "$R/"
# Atelier via Steam pour Mac : wehelper-mac charge @executable_path/libsteam_api.dylib
WEH="$ROOT/tools/wehelper"
[[ -f "$WEH/wehelper-mac" && -f "$WEH/libsteam_api.dylib" ]] || zsh "$WEH/build-wehelper.sh"
cp "$WEH/wehelper-mac" "$WEH/libsteam_api.dylib" "$R/"
codesign --force --sign - "$R/libsteam_api.dylib" "$R/wehelper-mac"
# Images du catalogue copiées telles quelles (Image("we.logo") les retrouve dans le bundle).
for set in we.logo we.placeholder; do
    cp "$(ls "$APPSRC/Resources/Assets.xcassets/$set.imageset/"*.png | head -1)" "$R/$set.png"
done
# Icône : .appiconset -> .icns avec iconutil (outil système).
ICONSET="$OUT/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
python3 -I - "$APPSRC/Resources/Assets.xcassets/AppIcon.appiconset" "$ICONSET" <<'EOF'
import json, os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
for img in json.load(open(os.path.join(src, "Contents.json")))["images"]:
    if "filename" not in img: continue
    base = img["size"].split("x")[0]
    scale = "" if img.get("scale", "1x") == "1x" else "@2x"
    shutil.copy(os.path.join(src, img["filename"]), os.path.join(dst, f"icon_{base}x{base}{scale}.png"))
EOF
iconutil -c icns "$ICONSET" -o "$R/AppIcon.icns"
# Traductions : Localizable.xcstrings -> <langue>.lproj/Localizable.strings.
python3 -I - "$APPSRC/Localizable.xcstrings" "$R" <<'EOF'
import json, os, sys
cat = json.load(open(sys.argv[1], encoding="utf-8"))
out = {}
for key, entry in cat["strings"].items():
    for lang, loc in entry.get("localizations", {}).items():
        unit = loc.get("stringUnit")
        if unit and unit.get("value") is not None:
            out.setdefault(lang, {})[key] = unit["value"]
esc = lambda s: s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
for lang, table in out.items():
    d = os.path.join(sys.argv[2], f"{lang}.lproj"); os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8") as f:
        for k, v in sorted(table.items()): f.write(f'"{esc(k)}" = "{esc(v)}";\n')
EOF

echo "==> Info.plist"
P="$APP/Contents/Info.plist"
cp "$SRC/Open-Wallpaper-Engine-Info.plist" "$P"
pb() { /usr/libexec/PlistBuddy -c "$1" "$P" >/dev/null; }
pb "Add :CFBundleExecutable string Open Wallpaper Engine"
pb "Add :CFBundleIdentifier string com.haren724.open-wallpaper-engine"
pb "Add :CFBundleName string Open Wallpaper Engine"
pb "Add :CFBundlePackageType string APPL"
pb "Add :CFBundleShortVersionString string 0.6.0-mac"
pb "Add :CFBundleVersion string 1"
pb "Add :CFBundleIconFile string AppIcon"
pb "Add :LSMinimumSystemVersion string 13.0"
pb "Add :NSPrincipalClass string NSApplication"
pb "Add :CFBundleDevelopmentRegion string en"
pb "Add :LSApplicationCategoryType string public.app-category.entertainment"

echo "==> Signature locale"
# Pas de bac à sable : l'app doit lire ~/Jeux et lancer Steam (Wine) pour les abonnements.
ENT="$OUT/app.entitlements"
cat > "$ENT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.network.client</key><true/></dict></plist>
EOF
codesign --force --sign - --entitlements "$ENT" "$APP"
echo "==> Prêt : $APP"

if [[ "${1:-}" == "--install" ]]; then
    osascript -e 'quit app "Open Wallpaper Engine"' 2>/dev/null || true
    sleep 1; pkill -x "Open Wallpaper Engine" 2>/dev/null || true
    rm -rf "/Applications/Open Wallpaper Engine.app"
    ditto "$APP" "/Applications/Open Wallpaper Engine.app"
    echo "==> Installé dans /Applications"
fi
