//
//  ExplorerItemMenu.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/29.
//

import SwiftUI

struct ExplorerItemMenu: SubviewOfContentView {
    
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    
    var hoveredWallpaper: WEWallpaper
    
    init(contentViewModel viewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel, current hoveredWallpaper: WEWallpaper) {
        self.wallpaperViewModel = wallpaperViewModel
        self.viewModel = viewModel
        self.hoveredWallpaper = hoveredWallpaper
    }
    
    var body: some View {
        Group {
            Section {
                Button {
                    Playlist.shared.toggle(hoveredWallpaper.wallpaperDirectory)
                } label: {
                    if Playlist.shared.contains(hoveredWallpaper.wallpaperDirectory) {
                        Label("Remove from Playlist", systemImage: "minus")
                    } else {
                        Label("Add to Playlist", systemImage: "plus")
                    }
                }
                Button {
                    viewModel.hoveredWallpaper = hoveredWallpaper
                    viewModel.isUnsubscribeConfirming = true
                } label: {
                    if WallpaperLibrary.workshopID(of: hoveredWallpaper.wallpaperDirectory) != nil {
                        Label("Unsubscribe", systemImage: "xmark")
                    } else {
                        Label("Delete", systemImage: "trash")
                    }
                }
                Button {
                    viewModel.toggleFavorite(hoveredWallpaper)
                } label: {
                    if viewModel.isFavorite(hoveredWallpaper) {
                        Label("Remove from Favorites", systemImage: "heart.slash.fill")
                    } else {
                        Label("Add to Favorites", systemImage: "heart.fill")
                    }
                }
            }
            
            Section {
                Button {
                    if let id = WallpaperLibrary.workshopID(of: hoveredWallpaper.wallpaperDirectory) {
                        NSWorkspace.shared.open(URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")!)
                    }
                } label: {
                    Label("Open in Workshop", systemImage: "cloud.fill")
                }.disabled(WallpaperLibrary.workshopID(of: hoveredWallpaper.wallpaperDirectory) == nil)
                Menu("Related Wallpapers") {
                    Link(destination: URL(string: "https://github.com/haren724/open-wallpaper-engine-mac")!) {
                        Label("Browse All By", systemImage: "person.fill")
                    }
                    Link(destination: URL(string: "https://github.com/haren724/open-wallpaper-engine-mac")!) {
                        Label("Browse Presets", systemImage: "cloud.fill")
                    }
                }.disabled(true)
                Menu("Report & Block") {
                    Button(role: .destructive) {
                        
                    } label: {
                        Label("Report", systemImage: "exclamationmark.triangle.fill")
                    }
                    Button {
                        
                    } label: {
                        Label("Manage Blocklist", systemImage: "hand.raised.fill")
                    }
                }.disabled(true)
            }
            
            Section {
                Button {
                    
                } label: {
                    Label("Assign Hotkey", systemImage: "command.square")
                }.disabled(true)
                Button {
                    NSWorkspace.shared.selectFile(nil,
                                                  inFileViewerRootedAtPath: hoveredWallpaper.wallpaperDirectory.path(percentEncoded: false))
                } label: {
                    Label("Open in Finder", systemImage: "folder.badge.gearshape")
                }
            }
        }
        .labelStyle(.titleAndIcon)
    }
}
