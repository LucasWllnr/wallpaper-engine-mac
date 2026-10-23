# Wallpaper Engine sur Mac

Fonds d'écran animés de l'Atelier **Wallpaper Engine** sur macOS (Apple Silicon), avec Steam pour Mac.
Fork complété d'[Open Wallpaper Engine](https://github.com/haren724/open-wallpaper-engine-mac) (v0.5.2, GPL-3.0)
et rendu fidèle des scènes par [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) porté sur macOS.

Condition pour l'utiliser : Steam pour Mac installé, connecté à un compte qui possède Wallpaper Engine.

## Fonctions

- **Atelier** : recherche, tris, filtres (type, âge, résolution, tags), pages, fiche détaillée ; sans clé API
  (la page publique de l'Atelier contient la réponse `QueryFiles`).
- **S'abonner / se désabonner** depuis l'app : `wehelper-mac` charge `libsteam_api.dylib` en tant que
  Wallpaper Engine (appid 431960) et passe par Steam pour Mac, qui télécharge les fonds.
- **Découvrir** : tendances, populaires, compatibles Mac, mieux notés, nouveautés.
- **Bibliothèque** : recherche, tri (nom, favoris, taille, dates), filtres, favoris, playlist (rotation
  toutes les N minutes, ordre ou aléatoire, JSON), suppression / désabonnement.
- **Fiche d'un fond** : propriétés du fond (cases, curseurs, couleurs, listes, texte), presets (charger,
  enregistrer, appliquer à tous, copier, réinitialiser), volume, vitesse et cadrage des vidéos, auteur et
  statistiques de l'Atelier.
- **Types** : vidéo, web, scènes. Scènes rendues avec les vrais shaders de Wallpaper Engine
  (linux-wallpaperengine) ; si une scène n'y passe pas, rendu Mac intégré (Core Animation, SceneKit).
- **Performances** : FPS réglable, pause quand rien n'est visible (écran éteint, session verrouillée, app en
  plein écran) ou sur batterie, grille d'aperçus légère.
- **macOS** : ouverture au démarrage, barre des menus teintée par le fond, icône dans la barre des menus.
- **Premier lancement** : Oui / Non pour chaque autorisation (démarrage, image du bureau, Steam).

## Arborescence

| Dossier | Contenu |
|---|---|
| `app/` | Code Swift / SwiftUI de l'app (projet Xcode d'origine + `Checks/` pour les vérifications) |
| `tools/build-owe.sh` | Construit l'app avec `swiftc` (sans Xcode) ; `--install` la copie dans /Applications |
| `tools/package-owe.sh` | Version pour tout le monde : moteur, CEF et bibliothèques dans l'app, image disque |
| `tools/bundle-dylibs.py` | Copie les bibliothèques Homebrew dans l'app et réécrit leurs chemins |
| `tools/build-lwe.sh`, `tools/lwe-macos.patch` | Clone linux-wallpaperengine (commit `b016d7d`), applique le portage macOS, compile |
| `tools/wehelper/` | `wehelper.c` : abonnements à l'Atelier via l'API Steam |
| `tools/run-checks.sh` | Vérifications : API de l'Atelier, Steam, bibliothèque, scènes, rendu réel |
| `tools/lwe-shots.sh`, `tools/lwe-compare.py` | Rendu de chaque scène et comparaison avec son aperçu |
| `docs/` | Plan de départ, prototype de requête Atelier |

## Construire

Prérequis : Mac Apple Silicon, macOS 14+, outils en ligne de commande Xcode, [Homebrew](https://brew.sh).

```sh
# dépendances du moteur de scènes
brew install cmake glfw glew lz4 sdl2-compat ffmpeg mpv freetype pulseaudio libx11 libxext dbus

# 1. moteur de scènes (clone + patch + compilation, long la première fois : CEF est téléchargé)
zsh tools/build-lwe.sh

# 2. app (compile aussi wehelper-mac ; libsteam_api.dylib est pris dans un jeu Steam installé
#    ou via STEAM_API_LIB=<Steamworks SDK>/redistributable_bin/osx/libsteam_api.dylib)
zsh tools/build-owe.sh --install

# 3. image disque à distribuer -> app/build/Open-Wallpaper-Engine-<version>.dmg
zsh tools/package-owe.sh

# vérifications (toutes, ou seulement certaines parties)
zsh tools/run-checks.sh
zsh tools/run-checks.sh library
```

## Fichiers de Wallpaper Engine (scènes fidèles)

Les scènes utilisent les fichiers de Wallpaper Engine (`assets`, ≈ 800 Mo), qui ne sont pas dans ce repo.
Wallpaper Engine n'a qu'une version Windows : on télécharge son dépôt depuis la console Steam
(`steam://open/console`) avec `download_depot 431960 431961`. L'app les cherche dans
`~/Library/Application Support/Steam/steamapps/content/app_431960/depot_431961/assets`, ou à l'endroit
indiqué par `defaults write com.haren724.open-wallpaper-engine WallpaperEngineAssets <dossier>`.
Sans eux, les scènes passent par le rendu Mac intégré.

## Réglages utiles

```sh
# désactiver le rendu fidèle des scènes
defaults write com.haren724.open-wallpaper-engine UseFaithfulRenderer -bool NO
# autre moteur linux-wallpaperengine que celui de l'app
defaults write com.haren724.open-wallpaper-engine FaithfulEngineBinary <chemin>
```

## Distribution

L'app est signée ad hoc (pas de certificat Apple Developer) : au premier lancement, macOS la bloque ;
Réglages Système > Confidentialité et sécurité > « Ouvrir quand même ». Mode d'emploi : `tools/dmg-readme.txt`.

## Licence

GPL-3.0 (voir `app/LICENSE`), comme Open Wallpaper Engine et linux-wallpaperengine.
Projet non affilié à Wallpaper Engine ni à Valve. `libsteam_api.dylib` (Steamworks SDK) n'est pas fourni.
