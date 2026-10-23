#!/bin/zsh
# Compile et lance les vérifications d'Open Wallpaper Engine (API, Steam, bibliothèque, scènes, visuel).
# Usage : zsh tools/run-checks.sh [api steam library scenes visual]   (OWE_SRC=<source> pour un worktree,
#         OWE_CHECK_IDS=id1,id2 pour ne photographier que ces scènes)
set -uo pipefail
ROOT="${0:A:h:h}"
SRC="${OWE_SRC:-$ROOT/app}"
OUT="$SRC/build/checks"
mkdir -p "$OUT"
find "$SRC/Open Wallpaper Engine" -name "*.swift" -not -name main.swift -not -path "*/Preview Content/*" -print0 \
    | xargs -0 swiftc -module-name Open_Wallpaper_Engine -target arm64-apple-macos13.0 -O \
        "$SRC/Checks/main.swift" -o "$OUT/owe-checks" 2>&1 | grep -E "error" && exit 2
cp "$ROOT/tools/wehelper/wehelper-mac" "$ROOT/tools/wehelper/libsteam_api.dylib" "$OUT/"
# Les captures sont faites ici (le shell a l'autorisation « Enregistrement de l'écran »)
"$OUT/owe-checks" "$OUT/captures" "$@" | while IFS= read -r line; do
    if [[ "$line" == OWE_CAPTURE\ * ]]; then
        parts=(${=line})
        screencapture -x -R "${parts[2]}" "${parts[3]}"
    else
        print -r -- "$line"
    fi
done
