//
//  ExplorerTopBar.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI

struct ExplorerTopBar: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    
    @EnvironmentObject var globalSettingsViewModel: GlobalSettingsViewModel
    
    init(contentViewModel viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }
    
    var body: some View {
        HStack {
            TextField("Search", text: $viewModel.searchText)
                .overlay {
                    HStack {
                        Spacer()
                        Button {
                            viewModel.searchText = ""
                        } label: {
                            Image(systemName: viewModel.searchText.isEmpty ? "magnifyingglass" : "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 4)
                    }
                }
                .frame(width: 160)
            Button {
                viewModel.isFilterReveal.toggle()
            } label: {
                Label("Filter Results", systemImage: "checklist.checked")
            }
            .buttonStyle(.borderedProminent)
            if globalSettingsViewModel.settings.autoRefresh {
                Button {
                    viewModel.refresh()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
            Spacer()
            Button {
                viewModel.sortingSequence = viewModel.sortingSequence == .increased ? .decreased : .increased
            } label: {
                Image(systemName: viewModel.sortingSequence == .increased ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
            }
            .buttonStyle(.plain)
            Picker("Sort", selection: $viewModel.sortingBy) {
                Text("Name").tag(WEWallpaperSortingMethod.name)
                Text("Favorite").tag(WEWallpaperSortingMethod.likes)
                Text("File Size").tag(WEWallpaperSortingMethod.size)
                Text("Subscription Date").tag(WEWallpaperSortingMethod.dateSubscribed)
                Text("Last Updated").tag(WEWallpaperSortingMethod.dateAdded)
            }
            .labelsHidden()
            .frame(width: 160)
        }
    }
}
