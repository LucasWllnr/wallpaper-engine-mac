//
//  ExplorerItem.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/25.
//

import SwiftUI

struct ExplorerItem: SubviewOfContentView {
    
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    
    var wallpaper: WEWallpaper
    
    /// Local so hovering one item does not re-render the whole grid
    @State private var isHovered = false
    
    var body: some View {
        ZStack(alignment: .bottom) {
            GifImage(contentsOf: wallpaper.project.preview.isEmpty
                     ? Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")!
                     : wallpaper.wallpaperDirectory.appending(path: wallpaper.project.preview),
                     animates: isHovered)
            .resizable()
            .scaleEffect(isHovered ? 1.2 : 1.0)
            .aspectRatio(1.0, contentMode: .fit)
            .clipped()
            
            Text(wallpaper.project.title)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30)
                .padding(4)
                .background(Color(white: 0, opacity: isHovered ? 0.4 : 0.2))
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(white: isHovered ? 0.9 : 0.7))
        }
        .onHover { isHovered = $0 }
        .animation(.spring(), value: isHovered)
        .selected(wallpaper.wallpaperDirectory == wallpaperViewModel.currentWallpaper.wallpaperDirectory)
        .border(Color.accentColor, width: isHovered ? 1.0 : 0)
        .onTapGesture {
            wallpaperViewModel.nextCurrentWallpaper = wallpaper
        }
    }
}
