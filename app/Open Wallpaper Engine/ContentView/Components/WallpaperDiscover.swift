//
//  WallpaperDiscover.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/21.
//

import SwiftUI

/// "Discover" tab: rows of Workshop selections, like Wallpaper Engine's home page
struct WallpaperDiscover: View {
    @ObservedObject var contentViewModel: ContentViewModel
    @ObservedObject var workshopViewModel: WorkshopViewModel

    private struct Shelf: Identifiable {
        var id: String
        var title: LocalizedStringKey
        var query: WorkshopQuery
    }

    private let shelves: [Shelf] = [
        Shelf(id: "today", title: "Trending Today", query: WorkshopQuery(sort: .trendDay, requiredTags: ["Everyone"])),
        Shelf(id: "week", title: "Most Popular This Week", query: WorkshopQuery(sort: .trendWeek, requiredTags: ["Everyone"])),
        Shelf(id: "video", title: "Plays on Mac: Videos", query: WorkshopQuery(sort: .trendMonth, requiredTags: ["Video", "Everyone"])),
        Shelf(id: "web", title: "Plays on Mac: Web", query: WorkshopQuery(sort: .trendMonth, requiredTags: ["Web", "Everyone"])),
        Shelf(id: "top", title: "Top Rated of All Time", query: WorkshopQuery(sort: .topRated, requiredTags: ["Everyone"])),
        Shelf(id: "approved", title: "Approved by the Developers", query: WorkshopQuery(sort: .trendMonth, requiredTags: ["Approved", "Everyone"])),
        Shelf(id: "new", title: "New Arrivals", query: WorkshopQuery(sort: .mostRecent, requiredTags: ["Everyone"]))
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(shelves) { shelf in
                    DiscoverShelf(title: shelf.title, query: shelf.query) { item in
                        workshopViewModel.selected = item
                        contentViewModel.topTabBarSelection = 2
                    }
                }
            }
            .padding(.vertical)
        }
    }
}

private struct DiscoverShelf: View {
    var title: LocalizedStringKey
    var query: WorkshopQuery
    var open: (WorkshopItem) -> Void

    @State private var items = [WorkshopItem]()
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.bold())
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 10) {
                    if items.isEmpty {
                        if failed {
                            Text("Could not reach the Steam Workshop.").foregroundStyle(Color.secondary)
                        } else {
                            ForEach(0..<6, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.secondary.opacity(0.15))
                                    .frame(width: 180, height: 180)
                            }
                        }
                    }
                    ForEach(items) { item in
                        WorkshopItemCell(item: item, isSelected: false)
                            .frame(width: 180, height: 180)
                            .onTapGesture { open(item) }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .task {
            guard items.isEmpty else { return }
            do {
                items = Array(try await WorkshopService.shared.search(query).items.prefix(15))
            } catch {
                failed = true
            }
        }
    }
}
