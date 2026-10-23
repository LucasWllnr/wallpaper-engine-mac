# Compare chaque rendu linux-wallpaperengine (<out>/<id>.png) avec l'aperçu officiel du fond (preview.*).
# Les deux images sont recadrées au centre en carré puis réduites en 32x32 (sips, sans dépendance Python).
# Mesures : écart moyen par pixel (structure + couleur), écart de luminosité, écart de couleur moyenne,
# rendu uniforme (écart type quasi nul = scène cassée). Rapport trié dans <out>/report.tsv.
import glob, os, struct, subprocess, sys, tempfile

N = 32


def thumb(path, tmp):
    dims = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path], capture_output=True, text=True).stdout
    w, h = (int(l.split()[-1]) for l in dims.splitlines()[1:3])
    side = min(w, h)
    out = os.path.join(tmp, os.path.basename(path) + ".bmp")
    subprocess.run(["sips", "-c", str(side), str(side), "-z", str(N), str(N), "-s", "format", "bmp", path, "--out", out],
                   capture_output=True)
    data = open(out, "rb").read()
    offset, = struct.unpack_from("<I", data, 10)
    width, height = struct.unpack_from("<ii", data, 18)
    bpp, = struct.unpack_from("<H", data, 28)
    step = bpp // 8
    row = (width * step + 3) & ~3
    pixels = []
    for y in range(abs(height)):
        base = offset + y * row
        for x in range(width):
            b, g, r = data[base + x * step: base + x * step + 3]
            pixels.append((r, g, b))
    return pixels


def stats(px):
    n = len(px)
    mean = [sum(p[c] for p in px) / n for c in range(3)]
    lum = [0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2] for p in px]
    mlum = sum(lum) / n
    std = (sum((l - mlum) ** 2 for l in lum) / n) ** 0.5
    return mean, mlum, std


def main():
    out, dirs = sys.argv[1], sys.argv[2:]
    rows = []
    with tempfile.TemporaryDirectory() as tmp:
        for d in dirs:
            sid = os.path.basename(d.rstrip("/"))
            png = os.path.join(out, sid + ".png")
            previews = [p for p in glob.glob(os.path.join(d, "preview.*")) if p.lower().endswith((".jpg", ".jpeg", ".png", ".gif"))]
            if not os.path.exists(png) or os.path.getsize(png) == 0:
                rows.append((999, sid, "ÉCHEC", "pas de rendu", ""))
                continue
            if not previews:
                rows.append((-1, sid, "?", "pas d'aperçu", ""))
                continue
            a, b = thumb(png, tmp), thumb(previews[0], tmp)
            diff = sum(abs(p[c] - q[c]) for p, q in zip(a, b) for c in range(3)) / (len(a) * 3) / 2.55
            (ma, la, sa), (mb, lb, _) = stats(a), stats(b)
            dlum = (la - lb) / 2.55
            dcol = sum((ma[c] - mb[c]) ** 2 for c in range(3)) ** 0.5 / 2.55
            # l'aperçu est une image fixe parfois recadrée : la luminosité et la couleur comptent plus que les pixels
            close = abs(dlum) < 8 and dcol < 10
            verdict = "uniforme" if sa < 2 else ("ok" if close and diff < 20 else ("à voir" if close or diff < 20 else "écart"))
            rows.append((diff, sid, verdict, f"écart {diff:4.1f}%  lum {dlum:+5.1f}%  couleur {dcol:4.1f}%", previews[0]))
    rows.sort(key=lambda r: -r[0])
    with open(os.path.join(out, "report.tsv"), "w") as f:
        for r in rows:
            f.write("\t".join(str(x) for x in r[1:]) + "\n")
    counts = {}
    for r in rows:
        counts[r[2]] = counts.get(r[2], 0) + 1
    print("bilan :", ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
    print("les plus éloignés de l'aperçu :")
    for r in rows[:12]:
        print(f"  {r[1]:>12}  {r[2]:<9} {r[3]}")


main()
