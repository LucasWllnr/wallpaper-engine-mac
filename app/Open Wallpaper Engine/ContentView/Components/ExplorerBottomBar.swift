//
//  ExplorerBottomBar.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI
import UniformTypeIdentifiers

struct ExplorerBottomBar: View {
    @ObservedObject var playlist = Playlist.shared
    @ObservedObject var wallpaperViewModel = AppDelegate.shared.wallpaperViewModel
    
    @State private var isConfiguring = false
    
    var body: some View {
        VStack {
            HStack {
                Text("Playlist").font(.largeTitle)
                HStack(spacing: 2) {
                    Button(action: loadPlaylist) {
                        Label("Load", systemImage: "folder.fill")
                    }
                    Button(action: savePlaylist) {
                        Label("Save", systemImage: "square.and.arrow.down.fill")
                    }
                    Button {
                        isConfiguring = true
                    } label: {
                        Label("Configure", systemImage: "gearshape.2.fill")
                    }
                    .popover(isPresented: $isConfiguring) { PlaylistConfiguration().frame(width: 360) }
                    let current = wallpaperViewModel.currentWallpaper.wallpaperDirectory
                    Button {
                        playlist.toggle(current)
                    } label: {
                        if playlist.contains(current) {
                            Label("Remove Wallpaper", systemImage: "minus")
                        } else {
                            Label("Add Wallpaper", systemImage: "plus")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(wallpaperViewModel.currentWallpaper.project == .invalid)
                }
                Toggle("Play", isOn: $playlist.state.isActive)
                    .toggleStyle(.switch)
                    .disabled(playlist.state.items.isEmpty)
                Text("\(playlist.state.items.count) wallpapers")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                Button { } label: {
                    Label("Wallpaper Editor", systemImage: "pencil.and.ruler.fill")
                        .frame(width: 220)
                }
                .buttonStyle(.borderedProminent)
                .disabled(true)
                Button {
                    AppDelegate.shared.openImportFromFolderPanel()
                } label: {
                    Label("Open Wallpaper", systemImage: "arrow.up.bin.fill")
                        .frame(width: 220)
                }
                Spacer()
            }
        }    }
}

extension ExplorerBottomBar {
    private func savePlaylist() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Playlist.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? playlist.export().write(to: url, options: .atomic)
    }
    
    private func loadPlaylist() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        playlist.load(data)
    }
}

/// Wallpapers of the playlist and how they rotate
struct PlaylistConfiguration: View {
    @ObservedObject var playlist = Playlist.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playlist").font(.headline)
            List {
                ForEach(playlist.state.items, id: \.self) { path in
                    HStack {
                        Text(Self.title(of: path)).lineLimit(1)
                        Spacer()
                        Button {
                            playlist.state.items.removeAll { $0 == path }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                }
                .onMove { playlist.state.items.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(height: 200)
            .overlay {
                if playlist.state.items.isEmpty {
                    Text("Add wallpapers with « Add Wallpaper » or the right-click menu")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            Stepper(value: $playlist.state.minutes, in: 1...1440, step: 5) {
                Text("Change every \(Int(playlist.state.minutes)) min")
            }
            Toggle("Shuffle", isOn: $playlist.state.shuffle)
            HStack {
                Toggle("Play", isOn: $playlist.state.isActive)
                    .toggleStyle(.switch)
                Spacer()
                Button {
                    playlist.next()
                } label: {
                    Label("Next Wallpaper", systemImage: "forward.fill")
                }
            }
            .disabled(playlist.state.items.isEmpty)
        }
        .padding()
    }
    
    private static func title(of path: String) -> String {
        let url = URL(filePath: path).appending(path: "project.json")
        return (try? JSONDecoder().decode(WEProject.self, from: Data(contentsOf: url)))?.title ?? URL(filePath: path).lastPathComponent
    }
}
