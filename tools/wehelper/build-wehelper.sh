#!/bin/zsh
# Compile wehelper-mac : il charge libsteam_api.dylib en tant que Wallpaper Engine (appid 431960)
# et s'abonne / se désabonne aux fonds de l'Atelier via Steam pour Mac.
# libsteam_api.dylib (Valve, Steamworks SDK) n'est pas dans le repo : STEAM_API_LIB=<chemin>, sinon
# la première trouvée dans les jeux Steam installés (beaucoup de jeux Mac l'embarquent).
set -euo pipefail
HERE="${0:A:h}"
clang -O2 -Wall -arch arm64 -arch x86_64 -o "$HERE/wehelper-mac" "$HERE/wehelper.c"
echo "==> $HERE/wehelper-mac"
if [[ ! -f "$HERE/libsteam_api.dylib" ]]; then
    LIB="${STEAM_API_LIB:-$(find "$HOME/Library/Application Support/Steam/steamapps/common" -name libsteam_api.dylib 2>/dev/null | head -1)}"
    [[ -n "$LIB" && -f "$LIB" ]] || { echo "libsteam_api.dylib introuvable : téléchargez le Steamworks SDK (partner.steamgames.com) et relancez avec STEAM_API_LIB=<sdk>/redistributable_bin/osx/libsteam_api.dylib" >&2; exit 1; }
    cp "$LIB" "$HERE/libsteam_api.dylib"
fi
echo "==> $HERE/libsteam_api.dylib"
# Ancienne version Windows (Steam sous Wine), seulement si llvm-mingw est là
CC="$HERE/../../engine/llvm-mingw/bin/x86_64-w64-mingw32-gcc"
if [[ -x "$CC" ]]; then "$CC" -O2 -Wall -o "$HERE/wehelper.exe" "$HERE/wehelper.c"; echo "==> $HERE/wehelper.exe"; fi
