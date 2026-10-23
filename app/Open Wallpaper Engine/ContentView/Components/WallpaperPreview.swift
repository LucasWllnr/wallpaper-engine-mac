//
//  WallpaperPreview.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI
import UniformTypeIdentifiers

struct WallpaperPreview: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    
    @Environment(\.undoManager) var undoManager
    
    @State var isEditingId = ""
    @State var title = ""
    @State var newTag = ""
    
    @State var hoveredTag: String?
    @State var isTagsHovered = false
    
    @State var wallpaperSize = "??? MB"
    /// Bumped when a preset changes the values, so the properties editor reloads them
    @State var presetRevision = 0
    
    /// Workshop page data of a subscribed wallpaper and its author's public profile
    @State var workshopItem: WorkshopItem?
    @State var author: (name: String, avatar: URL?)?
    
    @AppStorage("VideoScaling") var videoScaling = "fill"
    
    init(contentViewModel viewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel) {
        self.viewModel = viewModel
        self.wallpaperViewModel = wallpaperViewModel
    }
    
    var directory: URL { wallpaperViewModel.currentWallpaper.wallpaperDirectory }
    
    var workshopID: String? { WallpaperLibrary.workshopID(of: directory) }
    
    /// Writes the title and tags into project.json, keeping every other field (WEProject only models a few)
    func saveProject(_ wallpaper: WEWallpaper) {
        let url = wallpaper.wallpaperDirectory.appending(path: "project.json")
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        json["title"] = wallpaper.project.title
        json["tags"] = wallpaper.project.tags
        guard let output = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return }
        try? output.write(to: url, options: .atomic)
        wallpaperViewModel.currentWallpaper = wallpaper
        viewModel.refresh()
    }
    
    var body: some View {
        VStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack {
                        GifImage(contentsOf: wallpaperViewModel.currentWallpaper.project.preview.isEmpty
                                 ? Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")!
                                 : directory.appending(path: wallpaperViewModel.currentWallpaper.project.preview))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .background(Color(nsColor: NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 16.0))
                            .frame(width: 280, height: 280)
                        HStack {
                            if isEditingId == "title" {
                                TextField("Wallpaper Title", text: $title)
                                    .onSubmit {
                                        var wallpaper = wallpaperViewModel.currentWallpaper
                                        
                                        wallpaper.project.title = title
                                        
                                        saveProject(wallpaper)
                                        
                                        isEditingId = ""
                                    }
                            } else {
                                Text(wallpaperViewModel.currentWallpaper.project.title.isEmpty ? "Untitled" : wallpaperViewModel.currentWallpaper.project.title)
                                    .frame(minWidth: 50)
                                    .id("title")
                                    .lineLimit(1)
                                    .onTapGesture(count: 2) {
                                        title = wallpaperViewModel.currentWallpaper.project.title
                                        isEditingId = "title"
                                    }
                                Image(systemName: "square.and.pencil")
                            }
                            
                        }
                    }
                    HStack {
                        AsyncImage(url: author?.avatar) { image in
                            image.resizable()
                        } placeholder: {
                            Image("we.placeholder").resizable()
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text(author?.name ?? (workshopID == nil ? "My Wallpaper" : "Unknown Author"))
                    }
                    HStack {
                        if let item = workshopItem {
                            HStack(spacing: 8) {
                                Label("\(item.subscriptions ?? 0)", systemImage: "person.2.fill")
                                Label("\(item.favorited ?? 0)", systemImage: "star.fill")
                                if let updated = item.time_updated {
                                    Label(Date(timeIntervalSince1970: TimeInterval(updated)).formatted(date: .abbreviated, time: .omitted),
                                          systemImage: "clock.arrow.circlepath")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Button {
                            viewModel.toggleFavorite(wallpaperViewModel.currentWallpaper)
                        } label: {
                            Image(systemName: viewModel.isFavorite(wallpaperViewModel.currentWallpaper) ? "heart.fill" : "heart")
                                .foregroundStyle(.pink)
                        }
                        .buttonStyle(.plain)
                        .help("Favorite")
                    }
                    HStack {
                        Text(wallpaperViewModel.currentWallpaper.project.type)
                        Text(wallpaperSize)
                    }
                    .font(.footnote)
                    
                    ViewThatFits(in: .horizontal) {
                        tags.animation(.spring(), value: isTagsHovered)
                        ScrollView(.horizontal, showsIndicators: false) {
                            tags.animation(.spring(), value: isTagsHovered)
                        }
                    }
                    
                    .onHover { isTagsHovered = $0 }
                    
                    if isEditingId == "tags" {
                        HStack {
                            Button {
                                newTag = ""
                                isEditingId = ""
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            TextField("New Tag", text: $newTag)
                                .onSubmit {
                                    defer {
                                        newTag = ""
                                        isEditingId = ""
                                    }
                                    
                                    guard !newTag.isEmpty else { return }
                                    
                                    var wallpaper = wallpaperViewModel.currentWallpaper
                                    
                                    var tags = wallpaper.project.tags ?? []
                                    
                                    tags = Array(Set(tags)) // remove duplicate items
                                    
                                    tags.append(newTag)
                                    
                                    tags = Array(Set(tags)) // remove duplicate items
                                    
                                    wallpaper.project.tags = tags.sorted()
                                    
                                    saveProject(wallpaper)
                                }
                        }
                    }
                    VStack(spacing: 3) {
                        Button {
                            viewModel.hoveredWallpaper = wallpaperViewModel.currentWallpaper
                            viewModel.isUnsubscribeConfirming = true
                        } label: {
                            Label(workshopID == nil ? "Delete" : "Unsubscribe",
                                  systemImage: workshopID == nil ? "trash" : "xmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        HStack(spacing: 3) {
                            let page = workshopID.map { "https://steamcommunity.com/sharedfiles/filedetails/?id=\($0)" } ?? ""
                            Button {
                                NSWorkspace.shared.open(URL(string: "https://steamcommunity.com/sharedfiles/filedetails/comments/\(workshopID ?? "")")!)
                            } label: {
                                Label("Comment", systemImage: "text.badge.star")
                                    .frame(maxWidth: .infinity)
                            }
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(page, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc.fill")
                            }
                            .help("Copy the Workshop link")
                            Button {
                                // reporting needs the Steam login of the Workshop page
                                NSWorkspace.shared.open(URL(string: page)!)
                            } label: {
                                Image(systemName: "exclamationmark.triangle.fill")
                            }
                            .help("Report on the Workshop page")
                        }
                        .disabled(workshopID == nil)
                    }
                    // MARK: Properties
                    HStack(spacing: 3) {
                        Text("Properties")
                        VStack {
                            Divider()
                                .frame(height: 1)
                                .overlay(Color.accentColor)
                        }
                    }
                    VStack(spacing: 16) {
                        WallpaperPropertiesView(directory: directory)
                            .id(presetRevision)
                        switch wallpaperViewModel.currentWallpaper.project.type.lowercased() {
                        case "video", "scene":
                            if wallpaperViewModel.currentWallpaper.project.type.lowercased() == "video" {
                                Picker(selection: $videoScaling) {
                                    Text("Fill").tag("fill")
                                    Text("Fit").tag("fit")
                                    Text("Stretch").tag("stretch")
                                } label: {
                                    Label("Scaling", systemImage: "aspectratio")
                                }
                            }
                            HStack {
                                Label("Volume", systemImage: "speaker.wave.3.fill")
                                Spacer()
                                Slider(value: $wallpaperViewModel.playVolume, in: 0...1).frame(width: 100)
                                Text(String(format: "%.0f", wallpaperViewModel.playVolume * 100) + "%")
                                    .frame(width: 35)
                            }
                            if wallpaperViewModel.currentWallpaper.project.type.lowercased() == "video" {
                                HStack {
                                    Label("Playback Rate", systemImage: "play.fill")
                                    Spacer()
                                    Slider(value: $wallpaperViewModel.playRate, in: 0...2, step: 0.1).frame(width: 100)
                                    Text(String(format: "%.01fx", wallpaperViewModel.playRate))
                                        .frame(width: 35)
                                }
                            }
                        case "web":
                            EmptyView()
                        default:
                            EmptyView()
                        }
                    }
                    VStack(spacing: 3) {
                        HStack(spacing: 3) {
                            Text("Your Presets")
                            VStack {
                                Divider()
                                    .frame(height: 1)
                                    .overlay(Color.accentColor)
                            }
                        }
                        Group {
                            HStack(spacing: 3) {
                                Button(action: loadPreset) {
                                    Label("Load", systemImage: "folder.fill")
                                        .frame(maxWidth: .infinity)
                                    
                                }
                                Button(action: savePreset) {
                                    Label("Save", systemImage: "square.and.arrow.down.fill")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            Button {
                                WallpaperProperties.applyToAll(from: directory, to: viewModel.allWallpapers.map(\.wallpaperDirectory))
                            } label: {
                                Label("Apply to all Wallpapers", systemImage: "list.bullet.rectangle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(String(decoding: WallpaperProperties.preset(of: directory), as: UTF8.self), forType: .string)
                            } label: {
                                Label("Share JSON", systemImage: "arrow.2.squarepath")
                                    .frame(maxWidth: .infinity)
                            }
                            .help("Copy the preset to the clipboard")
                            Button {
                                WallpaperProperties.reset(directory)
                                presetRevision += 1
                            } label: {
                                Label("Reset", systemImage: "arrow.triangle.2.circlepath")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }
                    }
                }
                .blur(radius: wallpaperViewModel.currentWallpaper.project == .invalid ? 16.0 : 0)
                .overlay {
                    if wallpaperViewModel.currentWallpaper.project == .invalid {
                        Text("Please select a valid wallpaper")
                    }
                }
                .disabled(wallpaperViewModel.currentWallpaper.project == .invalid ? true : false)
                .animation(.default, value: wallpaperViewModel.currentWallpaper.project)
                .padding([.horizontal, .top])
                .task(id: directory) {
                    workshopItem = nil
                    author = nil
                    guard let id = workshopID,
                          let item = try? await WorkshopService.shared.details(of: [id]).first else { return }
                    workshopItem = item
                    author = await Self.profile(of: item.creator)
                }
                .task(id: directory) {
                    // walking a big scene folder is slow: never on the main thread, never on every render
                    wallpaperSize = "??? MB"
                    let url = directory
                    let bytes = await Task.detached(priority: .utility) {
                        try? url.directoryTotalAllocatedSize(includingSubfolders: true)
                    }.value
                    if let bytes { wallpaperSize = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
                }
            }

            HStack {
                Spacer()
                Button {
                    AppDelegate.shared.mainWindowController.close()
                } label: {
                    Text("OK").frame(width: 50)
                }
                .buttonStyle(.borderedProminent)
                Button { 
                    AppDelegate.shared.mainWindowController.close()
                } label: {
                    Text("Cancel").frame(width: 50)
                }
            }
            .padding()
        }
    }
    
    /// Name and avatar from the public XML of a Steam profile
    static func profile(of steamID: String?) async -> (name: String, avatar: URL?)? {
        guard let steamID, let url = URL(string: "https://steamcommunity.com/profiles/\(steamID)?xml=1"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let xml = String(decoding: data, as: UTF8.self)
        func field(_ name: String) -> String? {
            guard let start = xml.range(of: "<\(name)><![CDATA["), let end = xml.range(of: "]]></\(name)>", range: start.upperBound..<xml.endIndex)
            else { return nil }
            return String(xml[start.upperBound..<end.lowerBound])
        }
        guard let name = field("steamID") else { return nil }
        return (name, field("avatarMedium").flatMap(URL.init(string:)))
    }
    
    private func savePreset() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(wallpaperViewModel.currentWallpaper.project.title) preset.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? WallpaperProperties.preset(of: directory).write(to: url, options: .atomic)
    }
    
    private func loadPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        WallpaperProperties.load(preset: data, into: directory)
        presetRevision += 1
    }
    
    /// Shows all tags about current wallpaper in horizontal
    var tags: some View {
        HStack {
            if let tags = wallpaperViewModel.currentWallpaper.project.tags {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .padding(5)
                        .background {
                            RoundedRectangle(cornerRadius: 25.0)
                                .colorInvert()
                                .foregroundStyle(Color.primary)
                            RoundedRectangle(cornerRadius: 25.0)
                                .stroke(Color.secondary, lineWidth: 1.6)
                        }
                        .overlay(alignment: .topTrailing) {
                            if hoveredTag == tag {
                                Button {
                                    var wallpaper = wallpaperViewModel.currentWallpaper
                                    
                                    guard var tags = wallpaper.project.tags else { return } // else case seems impossible, however much safer
                                    
                                    tags = Array(Set(tags)) // remove duplicate items
                                    
                                    guard let index = tags.firstIndex(where: { $0 == tag }) else { return }
                                    
                                    tags.remove(at: index)
                                    
                                    wallpaper.project.tags = tags
                                    
                                    saveProject(wallpaper)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.white, .red)
                                .symbolRenderingMode(.palette)
                                .offset(x: 5, y: -2.5)
                            }
                        }
                        .onHover { hovered in
                            if hovered {
                                hoveredTag = tag
                            } else {
                                hoveredTag = nil
                            }
                        }
                }
            } else {
                Text("No Tags")
                    .foregroundStyle(Color.secondary)
            }
            
            if isTagsHovered {
                Button {
                    isEditingId = "tags"
                } label: {
                    Image(systemName: "plus")
                        .font(.body)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.footnote)
        .lineLimit(1)
    }
}

extension URL {
    /// check if the URL is a directory and if it is reachable
    func isDirectoryAndReachable() throws -> Bool {
        guard try resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            return false
        }
        return try checkResourceIsReachable()
    }

    /// returns total allocated size of a the directory including its subFolders or not
    func directoryTotalAllocatedSize(includingSubfolders: Bool = false) throws -> Int? {
        guard try isDirectoryAndReachable() else { return nil }
        if includingSubfolders {
            guard
                let urls = FileManager.default.enumerator(at: self, includingPropertiesForKeys: nil)?.allObjects as? [URL] else { return nil }
            return try urls.lazy.reduce(0) {
                    (try $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0) + $0
            }
        }
        return try FileManager.default.contentsOfDirectory(at: self, includingPropertiesForKeys: nil).lazy.reduce(0) {
                 (try $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                    .totalFileAllocatedSize ?? 0) + $0
        }
    }
}
