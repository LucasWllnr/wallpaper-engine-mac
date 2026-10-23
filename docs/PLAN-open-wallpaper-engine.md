# Compléter Open Wallpaper Engine (branche `mac-complete`, base v0.5.2, GPL-3)

But : retrouver sur Mac les fonctions de Wallpaper Engine, à partir des mêmes requêtes Steam.

| # | Étape | Détail |
|---|-------|--------|
| 1 | Service Atelier (sans clé) | Page publique `steamcommunity.com/workshop/browse/?appid=431960…` : le bloc `<script id="valve-ssr-data">` → `renderContext.queryData` contient la réponse `QueryFiles` complète (résultats, total, pages). Paramètres : `searchtext`, `browsesort` (textsearch, trend + `days`, toprated, mostrecent, totaluniquesubscribers), `requiredtags[]`, `p`. Prototype : `docs/workshop-query-prototype.py`. |
| 2 | Onglet Workshop | Grille de vignettes, panneau de détail (titre, auteur, note, taille, tags), comme dans Wallpaper Engine. |
| 3 | Abonnement / téléchargement (sans clé) | Petit programme Windows (`wehelper.exe`, mingw) lancé sous Wine avec `steam_api64.dll` de Wallpaper Engine (appid 431960) : `ISteamUGC_v020` SubscribeItem / UnsubscribeItem / GetItemState / GetItemDownloadInfo. Steam (Wine) télécharge dans `~/Jeux/Wallpapers`. |
| 4 | Onglet Découvrir | Sélections : tendances du jour, mieux notés, nouveautés. |
| 5 | Bibliothèque | Import automatique de `~/Jeux/Wallpapers` (abonnements Steam + téléchargements). |
| 6 | Scènes 2D | Lecteur `scene.pkg` + `.tex` (LZ4, RGBA/DXT), calques d'images, planches animées, effets simples. 3D/particules plus tard. |

Prérequis : licence Xcode acceptée (`sudo xcodebuild -license accept`) ; Steam lancé (`./macplay steam`) pour les abonnements. Aucune clé API.
