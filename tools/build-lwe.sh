#!/bin/zsh
# Compile linux-wallpaperengine (rendu fidèle des scènes Wallpaper Engine) pour macOS Apple Silicon.
# Réglages macOS : CEF fourni en framework, macOS 14 minimum (std::format), tests kissfft désactivés.
# Patches appliqués aux sources : en-têtes X11 sous ENABLE_X11, #include <string>, retours à la ligne finaux.
set -uo pipefail
# sources du moteur (non incluses dans le repo) : version sur laquelle lwe-macos.patch a été fait
if [[ ! -d "${0:A:h:h}/engine/linux-wallpaperengine" ]]; then
    git clone --recursive https://github.com/Almamu/linux-wallpaperengine.git "${0:A:h:h}/engine/linux-wallpaperengine"
    git -C "${0:A:h:h}/engine/linux-wallpaperengine" checkout b016d7d1fdcf4e5fd2f9c9fa420a8aaa07fee02d
    git -C "${0:A:h:h}/engine/linux-wallpaperengine" submodule update --init --recursive
fi
SRC="${0:A:h:h}/engine/linux-wallpaperengine"
B="$SRC/build"
# correctifs macOS (rendu, shaders, animations, mode bureau) : appliqués une seule fois sur un clone propre
git -C "$SRC" apply --check "${0:A:h}/lwe-macos.patch" 2>/dev/null && git -C "$SRC" apply "${0:A:h}/lwe-macos.patch"
mkdir -p "$B"
cmake -S "$SRC" -B "$B" -DCMAKE_BUILD_TYPE=Release -DKISSFFT_TEST=OFF -DKISSFFT_TOOLS=OFF \
    -DCMAKE_PREFIX_PATH=/opt/homebrew \
    -DCMAKE_SHARED_LINKER_FLAGS="-L/opt/homebrew/lib" -DCMAKE_EXE_LINKER_FLAGS="-L/opt/homebrew/lib" \
    -DCMAKE_CXX_FLAGS="-Wno-error -Wno-newline-eof -Wno-deprecated-declarations" > "$B/configure.log" 2>&1
# CEF télécharge ses scripts pendant la configuration : on corrige la version minimale et -Werror
for f in "$B"/cef/cef_binary_*/cmake/cef_variables.cmake; do
    sed -i '' -e 's/set(CEF_TARGET_SDK               "11.0")/set(CEF_TARGET_SDK               "14.0")/' \
              -e 's/^    -Werror                         # Treat warnings as errors$/    # -Werror removed for the macOS build/' "$f"
done
FW=$(print -l "$B"/cef/cef_binary_*/Release/"Chromium Embedded Framework.framework" | head -1)
cmake -S "$SRC" -B "$B" -DCEF_LIB_RELEASE="$FW/Chromium Embedded Framework" -DCEF_LIB_DEBUG="$FW/Chromium Embedded Framework" >> "$B/configure.log" 2>&1
cmake --build "$B" -j 8 > "$B/build.log" 2>&1
grep -E "error:|NOTFOUND|ld: " "$B/build.log" | sort | uniq -c | head -10 | cut -c1-260
tail -2 "$B/build.log"
ls "$B/output" 2>/dev/null | head
