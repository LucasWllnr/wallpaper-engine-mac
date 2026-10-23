#!/bin/zsh
# Rendu fidèle (vrais shaders Wallpaper Engine via linux-wallpaperengine) de chaque scène installée,
# fenêtre cachée, arrêt dès que la capture est écrite, puis comparaison avec preview.* (lwe-compare.py).
# Usage : lwe-shots.sh [id ...]        (sans id : toutes les scènes trouvées)
# Variables : LWE_DELAY (images avant capture, 90), LWE_JOBS (rendus en parallèle, 3), LWE_OUT (dossier).
set -uo pipefail
zmodload zsh/datetime
ROOT="${0:A:h:h}"
BIN="$ROOT/engine/linux-wallpaperengine/build/output/linux-wallpaperengine"
ASSETS="${WE_ASSETS:-$HOME/Library/Application Support/Steam/steamapps/content/app_431960/depot_431961/assets}"
OUT="${LWE_OUT:-$ROOT/tests/lwe-shots}"
DELAY="${LWE_DELAY:-90}"
JOBS="${LWE_JOBS:-3}"

# Mode interne : un seul rendu (appelé en parallèle par xargs)
if [[ "${1:-}" == "--one" ]]; then
    dir="$2"; id="${dir:t}"; png="$OUT/$id.png"; log="$OUT/logs/$id.log"
    rm -f "$png"
    start=$EPOCHREALTIME
    LWE_HIDDEN_WINDOW=1 "$BIN" --assets-dir "$ASSETS" --window 0x0x1280x720 --scaling fill --fps 60 \
        --silent --noautomute --no-audio-processing --screenshot-delay "$DELAY" --screenshot "$png" "$dir" > "$log" 2>&1 &
    pid=$!
    last=-1
    for i in {1..150}; do
        sleep 0.2
        kill -0 $pid 2>/dev/null || break
        size=$(stat -f %z "$png" 2>/dev/null || echo 0)
        # PNG écrit par un thread détaché : on attend que la taille ne bouge plus
        (( size > 0 && size == last )) && break
        last=$size
    done
    kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null
    printf "%s\t%.1fs\t%s\n" "$id" $(( EPOCHREALTIME - start )) "$( [[ -s $png ]] && echo ok || echo ÉCHEC )"
    exit 0
fi

[[ -x "$BIN" ]] || { echo "moteur absent : lancer tools/build-lwe.sh"; exit 1; }
mkdir -p "$OUT/logs"
typeset -A seen
dirs=()
for base in "$HOME/Library/Application Support/Open Wallpaper Engine/Wallpapers" "$HOME/Library/Application Support/Steam/steamapps/workshop/content/431960"; do
    for d in "$base"/*(N/); do
        id="${d:t}"
        (( $# )) && [[ " $* " != *" $id "* ]] && continue
        [[ -n "${seen[$id]:-}" ]] && continue
        grep -qiE '"type"[[:space:]]*:[[:space:]]*"scene"' "$d/project.json" 2>/dev/null || continue
        seen[$id]=1; dirs+=("$d")
    done
done
echo "${#dirs} scène(s), $JOBS en parallèle, capture après $DELAY images → $OUT"
t0=$EPOCHREALTIME
print -l -- $dirs | tr '\n' '\0' | xargs -0 -P "$JOBS" -I{} zsh "$0" --one {} | tee "$OUT/timings.tsv"
printf "rendu total : %.0fs\n" $(( EPOCHREALTIME - t0 ))
python3 -I "$ROOT/tools/lwe-compare.py" "$OUT" $dirs
