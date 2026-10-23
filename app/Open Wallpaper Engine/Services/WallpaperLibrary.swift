//
//  WallpaperLibrary.swift
//  Open Wallpaper Engine
//
//  Where installed wallpapers live. The app is not sandboxed, so instead of the
//  container's Documents folder it reads the Steam Workshop folders of Wallpaper Engine
//  (Steam for Mac, and the earlier Steam under Wine) plus a folder for imported wallpapers.
//

import Foundation

enum WallpaperLibrary {
    /// Steam (Wine) workshop content of Wallpaper Engine: steamapps/workshop/content/431960
    static var workshopDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: "WorkshopContentPath"), !path.isEmpty {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return home.appending(path: "Jeux/Wallpapers", directoryHint: .isDirectory)
    }

    /// Workshop content downloaded by Steam for Mac (subscriptions made from this app)
    static var macWorkshopDirectory: URL {
        home.appending(path: "Library/Application Support/Steam/steamapps/workshop/content/431960", directoryHint: .isDirectory)
    }

    /// Wallpapers imported by drag & drop or "Wallpaper from Folder"
    static var importDirectory: URL {
        // ~/Jeux/Wallpapers-mac on the Mac this fork was made on, Application Support everywhere else
        let legacy = home.appending(path: "Jeux/Wallpapers-mac", directoryHint: .isDirectory)
        let url = FileManager.default.fileExists(atPath: legacy.path(percentEncoded: false)) ? legacy
            : home.appending(path: "Library/Application Support/Open Wallpaper Engine/Wallpapers", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var directories: [URL] { [importDirectory, macWorkshopDirectory, workshopDirectory] }

    /// Every folder containing a project.json, imports first; an item present in both
    /// workshop folders is listed once
    static var wallpaperURLs: [URL] {
        var seen = Set<String>()
        return directories.flatMap { directory -> [URL] in
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory.resolvingSymlinksInPath(),
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles)) ?? []
            return contents.filter {
                FileManager.default.fileExists(atPath: $0.appending(path: "project.json").path(percentEncoded: false))
                    && seen.insert($0.lastPathComponent).inserted
            }
        }
    }

    /// Folder of a workshop item: Steam for Mac's copy when present, else the Wine one
    static func directory(ofWorkshopItem id: String) -> URL {
        let mac = macWorkshopDirectory.appending(path: id, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: mac.appending(path: "project.json").path(percentEncoded: false)) {
            return mac
        }
        let wine = workshopDirectory.resolvingSymlinksInPath().appending(path: id, directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: wine.path(percentEncoded: false)) ? wine : mac
    }

    static func isInstalled(workshopItem id: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(ofWorkshopItem: id).appending(path: "project.json").path(percentEncoded: false))
    }

    /// Workshop id of a subscribed wallpaper, nil for an imported one
    static func workshopID(of directory: URL) -> String? {
        let parent = directory.deletingLastPathComponent().resolvingSymlinksInPath()
        guard parent != importDirectory.resolvingSymlinksInPath(), UInt64(directory.lastPathComponent) != nil else { return nil }
        return directory.lastPathComponent
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
}
