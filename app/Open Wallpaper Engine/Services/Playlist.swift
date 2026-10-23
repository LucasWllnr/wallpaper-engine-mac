//
//  Playlist.swift
//  Open Wallpaper Engine
//
//  Wallpaper Engine's playlist: wallpapers shown in turn (in order or shuffled) every few minutes.
//  Saved in the user defaults, and to/from JSON files to keep several playlists.
//

import Foundation

final class Playlist: ObservableObject {
    static let shared = Playlist()

    struct State: Codable, Equatable {
        /// Wallpaper folders
        var items = [String]()
        var minutes = 30.0
        var shuffle = false
        var isActive = false
    }

    @Published var state: State {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: "Playlist")
            if state.isActive != oldValue.isActive || state.minutes != oldValue.minutes { schedule() }
        }
    }

    private var timer: Timer?

    private init() {
        state = UserDefaults.standard.data(forKey: "Playlist").flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        schedule()
    }

    func contains(_ directory: URL) -> Bool { state.items.contains(directory.path(percentEncoded: false)) }

    func toggle(_ directory: URL) {
        let path = directory.path(percentEncoded: false)
        if let index = state.items.firstIndex(of: path) { state.items.remove(at: index) } else { state.items.append(path) }
    }

    /// Index of the wallpaper after `current`: the next one in order, or a different random one
    static func nextIndex(after current: Int?, count: Int, shuffle: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard shuffle, count > 1 else { return ((current ?? -1) + 1) % count }
        return (0..<count).filter { $0 != current }.randomElement()
    }

    /// Shows the next wallpaper of the playlist (missing folders are skipped)
    func next() {
        let items = state.items.filter { FileManager.default.fileExists(atPath: $0 + "/project.json") }
        let wallpapers = AppDelegate.shared.wallpaperViewModel
        let current = items.firstIndex(of: wallpapers.currentWallpaper.wallpaperDirectory.path(percentEncoded: false))
        guard let index = Self.nextIndex(after: current, count: items.count, shuffle: state.shuffle) else { return }
        let url = URL(filePath: items[index], directoryHint: .isDirectory)
        guard let data = try? Data(contentsOf: url.appending(path: "project.json")),
              let project = try? JSONDecoder().decode(WEProject.self, from: data) else { return }
        wallpapers.nextCurrentWallpaper = WEWallpaper(using: project, where: url)
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard state.isActive else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(1, state.minutes) * 60, repeats: true) { [weak self] _ in self?.next() }
    }

    func export() -> Data {
        (try? JSONEncoder().encode(state)) ?? Data()
    }

    @discardableResult
    func load(_ data: Data) -> Bool {
        guard let loaded = try? JSONDecoder().decode(State.self, from: data) else { return false }
        state = loaded
        return true
    }
}
