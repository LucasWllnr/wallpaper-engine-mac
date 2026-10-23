//
//  ContentViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import AVKit
import SwiftUI
import UniformTypeIdentifiers

class ContentViewModel: ObservableObject, DropDelegate {
    @AppStorage("SortingBy") var sortingBy: WEWallpaperSortingMethod = .name
    @AppStorage("SortingSequence") var sortingSequence: WEWallpaperSortingSequence = .increased
    
    @AppStorage("FRShowOnly")                   public var showOnly                     =                   FRShowOnly.none
    @AppStorage("FRType")                       public var type                         =                       FRType.all
    @AppStorage("FRAgeRating")                  public var ageRating                    =                  FRAgeRating.all
    @AppStorage("FRWidescreenResolution")       public var widescreenResolution         =       FRWidescreenResolution.all
    @AppStorage("FRUltraWidescreenResolution")  public var ultraWidescreenResolution    =  FRUltraWidescreenResolution.all
    @AppStorage("FRDualscreenResolution")       public var dualscreenResolution         =       FRDualscreenResolution.all
    @AppStorage("FRTriplescreenResolution")     public var triplescreenResolution       =     FRTriplescreenResolution.all
    @AppStorage("FRPortraitScreenResolution")   public var potraitscreenResolution      =   FRPortraitScreenResolution.all
    @AppStorage("FRMiscResolution")             public var miscResolution               =             FRMiscResolution.all
    @AppStorage("FRSource")                     public var source                       =                     FRSource.all
    @AppStorage("FRTag")                        public var tag                          =                        FRTag.all
    
    @AppStorage("FilterReveal") var isFilterReveal = false
    @AppStorage("WallpaperURLs") var wallpaperUrls = [URL]()
    @AppStorage("SelectedIndex") var selectedIndex = 0
    
    @AppStorage("ExplorerIconSize") var explorerIconSize: Double = 200
    
    /// Paths of the favourite wallpapers
    @AppStorage("Favorites") var favorites = [String]()
    
    @Published var searchText = ""
    
    @Published var isDisplaySettingsReveal = false
    @Published var importAlertPresented = false
    @Published var isStaging = false
    
    /// Remembered across launches (0 Installed, 1 Discover, 2 Workshop)
    @Published var topTabBarSelection: Int = UserDefaults.standard.integer(forKey: "TopTabBarSelection") {
        didSet { UserDefaults.standard.set(topTabBarSelection, forKey: "TopTabBarSelection") }
    }
    @Published var topTabBarHoverSelection: Int = -1
    
    @Published var isUnsafeWallpaperWarningPresented = false
    
    @Published var hoveredWallpaper: WEWallpaper?
    
    @Published var isUnsubscribeConfirming = false
    
    @AppStorage("WallpapersPerPage") var wallpapersPerPage: Int = 2
    
    var importAlertError: WPImportError? = nil
    
    init() {
        (allWallpapers, info) = Self.loadLibrary()
        watchLibrary()
    }

    convenience init(isStaging: Bool, topTabBarSelection: Int? = nil) {
        self.init()
        self.isStaging = isStaging
        if let topTabBarSelection { self.topTabBarSelection = topTabBarSelection }
    }
    
    /// current page index number is starting from '1'
    @Published public var currentPage: Int = 1
//    {
//        willSet {
//            self.currentPage = newValue > self.maxPage ? self.maxPage : newValue
//        }
//    }
    
    /// Every wallpaper of the library, without being filtered. Loaded once and reloaded by `refresh()`:
    /// views read it on every render, and decoding each project.json then made the whole UI lag
    @Published private(set) var allWallpapers = [WEWallpaper]()

    /// What sorting and filtering need beyond WEProject, read with the library
    struct LibraryInfo {
        var subscribed = Date.distantPast, updated = Date.distantPast
        var customizable = false, audioResponsive = false
    }
    private var info = [URL: LibraryInfo]()
    /// Folder sizes, computed in the background the first time the list is sorted by size
    @Published private var sizes = [URL: Int]()
    private var isSizing = false

    private var libraryWatchers = [DispatchSourceFileSystemObject]()
    private var pendingRefresh: DispatchWorkItem?

    private static func loadLibrary() -> ([WEWallpaper], [URL: LibraryInfo]) {
        var info = [URL: LibraryInfo]()
        let wallpapers = WallpaperLibrary.wallpaperURLs.map({ url in
            let projectURL = url.appending(path: "project.json")
            var item = LibraryInfo()
            item.subscribed = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            item.updated = (try? projectURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let data = try? Data(contentsOf: projectURL),
               let general = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["general"] as? [String: Any] {
                // every wallpaper has a scheme color, only the others make it customizable
                item.customizable = ((general["properties"] as? [String: Any]) ?? [:]).keys.contains { $0 != "schemecolor" }
                item.audioResponsive = general["supportsaudioprocessing"] as? Bool ?? false
            }
            info[url] = item
            if let data = try? Data(contentsOf: projectURL), let project = try? JSONDecoder().decode(WEProject.self, from: data) {
                return WEWallpaper(using: project, where: url)
            } else {
                return WEWallpaper(using: .invalid, where: url)
            }
        })
        return (wallpapers, info)
    }

    /// Reloads the list when a library folder gains or loses a wallpaper (imports, Steam downloads, deletions)
    private func watchLibrary() {
        for directory in WallpaperLibrary.directories {
            let descriptor = open(directory.resolvingSymlinksInPath().path(percentEncoded: false), O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in
                // Steam and copies write in bursts: refresh once they settle
                self?.pendingRefresh?.cancel()
                let refresh = DispatchWorkItem { self?.refresh() }
                self?.pendingRefresh = refresh
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: refresh)
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            libraryWatchers.append(source)
        }
    }
    
    private var filteredWallpapers: [WEWallpaper] {
        let favorites = Set(self.favorites)
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let result = allWallpapers.filter { wallpaper in
            let info = info[wallpaper.wallpaperDirectory] ?? LibraryInfo()
            
            // Age Rating
            var ageRating: FRAgeRating
            switch wallpaper.project.contentrating {
            case "Everyone":
                ageRating = .everyone
            case "Questionable":
                ageRating = .partialNudity
            case "Mature":
                ageRating = .mature
            default:
                ageRating = .none
            }
            guard ageRating == .none || self.ageRating.contains(ageRating) else { return false }
            
            // Type
            let type: FRType = switch wallpaper.project.type.lowercased() {
            case "scene": .scene
            case "video": .video
            case "web": .web
            case "application": .application
            default: .wallpaper
            }
            guard self.type.contains(type) else { return false }
            
            // Source
            let source: FRSource = WallpaperLibrary.workshopID(of: wallpaper.wallpaperDirectory) == nil ? .myWallpapers : .workshop
            guard self.source.contains(source) else { return false }
            
            // Genre tags ("Pixel art" matches "PixelArt"); untagged wallpapers are "Unspecified"
            if self.tag != .all {
                let indices = (wallpaper.project.tags ?? []).compactMap { tag in
                    FRTag.allOptions.firstIndex { $0.caseInsensitiveCompare(tag.replacingOccurrences(of: " ", with: "")) == .orderedSame }
                }
                let tags = indices.isEmpty ? FRTag.unspecifiedGenre : FRTag(rawValue: indices.reduce(0) { $0 | 1 << $1 })
                guard !self.tag.isDisjoint(with: tags) else { return false }
            }
            
            // Show only
            if showOnly.contains(.myFavourites), !favorites.contains(wallpaper.wallpaperDirectory.path(percentEncoded: false)) { return false }
            if showOnly.contains(.customizable), !info.customizable { return false }
            if showOnly.contains(.audioResponsive), !info.audioResponsive { return false }
            
            // Search
            if !query.isEmpty {
                let text = ([wallpaper.project.title] + (wallpaper.project.tags ?? [])).joined(separator: " ")
                guard text.localizedCaseInsensitiveContains(query) else { return false }
            }
            return true
        }
        return sorted(result, favorites: favorites)
    }
    
    private func sorted(_ wallpapers: [WEWallpaper], favorites: Set<String>) -> [WEWallpaper] {
        if sortingBy == .size && sizes.isEmpty && !isSizing { computeSizes() }
        let byName = { (a: WEWallpaper, b: WEWallpaper) in a.project.title.localizedStandardCompare(b.project.title) == .orderedAscending }
        let ascending = wallpapers.sorted { a, b in
            switch sortingBy {
            case .likes:
                let (fa, fb) = (favorites.contains(a.wallpaperDirectory.path(percentEncoded: false)), favorites.contains(b.wallpaperDirectory.path(percentEncoded: false)))
                return fa != fb ? fa : byName(a, b)
            case .size:
                return (sizes[a.wallpaperDirectory] ?? 0) < (sizes[b.wallpaperDirectory] ?? 0)
            case .dateSubscribed:
                return (info[a.wallpaperDirectory]?.subscribed ?? .distantPast) < (info[b.wallpaperDirectory]?.subscribed ?? .distantPast)
            case .dateAdded:
                return (info[a.wallpaperDirectory]?.updated ?? .distantPast) < (info[b.wallpaperDirectory]?.updated ?? .distantPast)
            default:
                return byName(a, b)
            }
        }
        return sortingSequence == .increased ? ascending : ascending.reversed()
    }
    
    private func computeSizes() {
        isSizing = true
        let urls = allWallpapers.map(\.wallpaperDirectory)
        Task.detached(priority: .utility) {
            var sizes = [URL: Int]()
            for url in urls { sizes[url] = (try? url.directoryTotalAllocatedSize(includingSubfolders: true)) ?? 0 }
            await MainActor.run { [sizes] in
                self.sizes = sizes
                self.isSizing = false
            }
        }
    }
    
    func isFavorite(_ wallpaper: WEWallpaper) -> Bool {
        favorites.contains(wallpaper.wallpaperDirectory.path(percentEncoded: false))
    }
    
    func toggleFavorite(_ wallpaper: WEWallpaper) {
        let path = wallpaper.wallpaperDirectory.path(percentEncoded: false)
        if let index = favorites.firstIndex(of: path) { favorites.remove(at: index) } else { favorites.append(path) }
    }
    
    /// Provide wallpapers information for UI, being filtered by FilterResults and divided in pages
    public var autoRefreshWallpapers: [WEWallpaper] {
        filteredWallpapers
//        let startIndex = (self.currentPage - 1) * self.wallpapersPerPage
//        let filteredWallpapers = self.filteredWallpapers
//        let clip = filteredWallpapers[startIndex..<filteredWallpapers.endIndex]
//        return Array(clip.prefix(self.wallpapersPerPage))
    }
    
    func toggleFilter() {
        isFilterReveal.toggle()
    }
    
    func alertImportModal(which error: WPImportError) {
        self.importAlertError = error
        self.importAlertPresented = true
    }
    
    func warningUnsafeWallpaperModal(which wallpaper: WEWallpaper) {
        self.isUnsafeWallpaperWarningPresented = true
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let proposal = DropProposal(operation: .copy)
        return proposal
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let itemProvider = info.itemProviders(for: [UTType.fileURL]).first
        else {
            alertImportModal(which: .unkown)
            return false
        }
        itemProvider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
            guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil)
            else {
                self?.alertImportModal(which: .unkown)
                return
            }
            // Do something with the file url
            // remember to dispatch on main in case of a @State change
            guard let wallpaper = try? FileWrapper(url: url)
            else{
                self?.alertImportModal(which: .unkown)
                return
            }
            
            if wallpaper.isDirectory {
                guard wallpaper.fileWrappers?["project.json"] != nil
                else{
                    self?.alertImportModal(which: .doesNotContainWallpaper)
                    return
                }
                DispatchQueue.main.async {
                    try? FileManager.default.copyItem(
                        at: url,
                        to: WallpaperLibrary.importDirectory
                            .appending(path: url.lastPathComponent)
                    )
                }
            } else if wallpaper.isRegularFile { // hello.mp4
                guard let filename = wallpaper.filename, [".mp4", ".mov"].contains(filename.suffix(4).lowercased()) else { return }
                
                let wallpaperDirectoryWrapper = FileWrapper(directoryWithFileWrappers: [filename: wallpaper])
                
                let projectData = WEProject(file: filename,
                                            preview: "preview.jpg",
                                            title: String(filename.prefix(filename.count - 4)),
                                            type: "video")
                
                // Generate a thumbnail (preview) image for importing video wallpaper
                let asset = AVAsset(url: url)
                let imageGenerator = AVAssetImageGenerator(asset: asset)
                imageGenerator.appliesPreferredTrackTransform = true
                let time = CMTimeMake(value: 1, timescale: 1) // 第一帧的时间
                imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { (_, cgImage, _, _, error) in
                    if let error = error {
                        print(error)
                    } else if let cgImage = cgImage {
                        if let data = NSBitmapImageRep(cgImage: cgImage).representation(using: NSBitmapImageRep.FileType.jpeg, properties: [:]) {
                            wallpaperDirectoryWrapper.addRegularFile(withContents: data, preferredFilename: "preview.jpg")
                            
                            wallpaperDirectoryWrapper.addRegularFile(withContents: try! JSONEncoder().encode(projectData), preferredFilename: "project.json")
                            
                            // Write to Work Directory
                            DispatchQueue.main.async {
                                do {
                                    try wallpaperDirectoryWrapper.write(
                                        to: WallpaperLibrary.importDirectory.appending(path: String(filename.prefix(filename.count - 4))),
                                        originalContentsURL: nil)
                                } catch {
                                    print(error)
                                    return
                                }
                            }
                        }
                    }
                }
            }
        }
        return true
    }
    
    public func refresh() {
        (allWallpapers, info) = Self.loadLibrary()
        sizes = [:]
    }
    
    /// Provide a filter reset to default function, usually being used to show all wallpapers without filtered
    public func reset() {
        self.showOnly                   = .none // notice it's show ONLY, it acts oppositely to the others
        self.type                       = .all
        self.ageRating                  = .all
        self.type                       = .all
        self.ageRating                  = .all
        self.widescreenResolution       = .all
        self.ultraWidescreenResolution  = .all
        self.dualscreenResolution       = .all
        self.triplescreenResolution     = .all
        self.potraitscreenResolution    = .all
        self.miscResolution             = .all
        self.source                     = .all
        self.tag                        = .all
    }
}

extension Array: RawRepresentable where Element: Codable {
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode([Element].self, from: data)
        else {
            return nil
        }
        self = result
    }
    
    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let result = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return result
    }
}
