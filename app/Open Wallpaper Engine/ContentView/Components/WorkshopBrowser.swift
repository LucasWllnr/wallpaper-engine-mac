//
//  WorkshopBrowser.swift
//  Open Wallpaper Engine
//
//  "Workshop" tab: search, sort and filter the Steam Workshop like Wallpaper Engine does.
//

import SwiftUI

@MainActor
final class WorkshopViewModel: ObservableObject {
    static let typeTags = ["Scene", "Video", "Web", "Application"]
    static let ratingTags = ["Everyone", "Questionable", "Mature"]
    static let featureTags = ["Approved", "Audio responsive", "Customizable", "3D", "HDR", "Puppet Warp",
                              "Media Integration", "Video Texture", "No Animation", "User Shortcut", "Preset"]
    static let resolutionTags = ["1280 x 720", "1366 x 768", "1920 x 1080", "2560 x 1440", "3840 x 2160",
                                 "Ultrawide Standard Definition", "Ultrawide 2560 x 1080", "Ultrawide 3440 x 1440",
                                 "Dual 3840 x 1080", "Dual 5120 x 1440", "Dual 7680 x 2160",
                                 "Portrait 720 x 1280", "Portrait 1080 x 1920", "Portrait 1440 x 2560", "Portrait 2160 x 3840",
                                 "Dynamic resolution", "Other resolution"]
    static let genreTags = ["Abstract", "Animal", "Anime", "Cartoon", "CGI", "Cyberpunk", "Fantasy", "Game", "Girls",
                            "Guys", "Landscape", "Medieval", "Memes", "MMD", "Music", "Nature", "Pixel art", "Relaxing",
                            "Retro", "Sci-Fi", "Sports", "Technology", "Television", "Vehicle", "Unspecified"]

    @AppStorage("WorkshopSort") var sort: WorkshopSort = .trendYear
    /// Empty string means "any"
    @AppStorage("WorkshopType") var type = ""
    @AppStorage("WorkshopRating") var rating = "Everyone"

    @Published var searchText = ""
    @Published var resolution = ""
    @Published var features = Set<String>()
    @Published var genres = Set<String>()
    @Published var page = 1

    @Published private(set) var result = WorkshopPage()
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var selected: WorkshopItem?

    private var loadTask: Task<Void, Never>?

    var query: WorkshopQuery {
        var tags = [String]()
        if !type.isEmpty { tags.append(type) }
        if !rating.isEmpty { tags.append(rating) }
        if !resolution.isEmpty { tags.append(resolution) }
        tags += features.sorted() + genres.sorted()
        return WorkshopQuery(searchText: searchText, sort: sort, requiredTags: tags, page: page)
    }

    /// Reload from page 1 (filters changed); searches are debounced
    func reload(debounce: Bool = false) {
        page = 1
        load(debounce: debounce)
    }

    func load(debounce: Bool = false) {
        loadTask?.cancel()
        let query = self.query
        loadTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(450)) }
            guard !Task.isCancelled else { return }
            isLoading = true
            defer { isLoading = false }
            do {
                let page = try await WorkshopService.shared.search(query)
                guard !Task.isCancelled else { return }
                result = page
                errorMessage = nil
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func go(to page: Int) {
        self.page = min(max(page, 1), max(result.totalPages, 1))
        load()
    }

    func resetFilters() {
        type = ""; rating = "Everyone"; resolution = ""
        features = []; genres = []
        reload()
    }

    func author(of item: WorkshopItem) -> String {
        item.creator.flatMap { result.authors[$0] } ?? "Unknown author"
    }

    /// Video and Web wallpapers play natively; scenes are partly rendered (SceneWallpaperView)
    static func playsOnMac(_ item: WorkshopItem) -> Bool {
        ["Video", "Web", "Scene"].contains(item.wallpaperType ?? "")
    }

    static func badgeColor(_ item: WorkshopItem) -> Color {
        switch item.wallpaperType {
        case "Video", "Web": .green
        case "Scene": .orange
        default: .gray
        }
    }
}

// MARK: - Browser

struct WorkshopBrowser: View {
    @ObservedObject var viewModel: WorkshopViewModel
    @ObservedObject var contentViewModel: ContentViewModel

    var body: some View {
        HStack(spacing: 0) {
            WorkshopFilterSidebar(viewModel: viewModel)
                .frame(width: contentViewModel.isFilterReveal ? 225 : 0)
                .opacity(contentViewModel.isFilterReveal ? 1 : 0)
                .animation(.spring(), value: contentViewModel.isFilterReveal)
            VStack(spacing: 8) {
                topBar
                ZStack {
                    grid
                    if viewModel.isLoading && viewModel.result.items.isEmpty {
                        ProgressView()
                    }
                    if let message = viewModel.errorMessage {
                        VStack(spacing: 10) {
                            Text(message).foregroundStyle(Color.secondary)
                            Button("Retry") { viewModel.load() }
                        }
                    }
                }
                pagination
            }
            .padding(.leading, contentViewModel.isFilterReveal ? 10 : 0)
        }
        .onAppear {
            if viewModel.result.items.isEmpty { viewModel.load() }
            WorkshopSubscriptions.shared.onInstalled = { [weak contentViewModel] _ in contentViewModel?.refresh() }
            WorkshopSubscriptions.shared.refresh(viewModel.result.items.map(\.id))
        }
        .onChange(of: viewModel.result.items.map(\.id)) { ids in
            WorkshopSubscriptions.shared.refresh(ids)
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                contentViewModel.toggleFilter()
            } label: {
                Label("Filter Results", systemImage: "line.3.horizontal.decrease.circle")
            }
            TextField("Search the Workshop", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { viewModel.reload() }
                .onChange(of: viewModel.searchText) { _ in viewModel.reload(debounce: true) }
            Picker("", selection: $viewModel.sort) {
                ForEach(WorkshopSort.allCases) { sort in
                    Text(LocalizedStringKey(sort.title)).tag(sort)
                }
            }
            .frame(width: 220)
            .disabled(!viewModel.searchText.isEmpty)
            .onChange(of: viewModel.sort) { _ in viewModel.reload() }
            if viewModel.isLoading {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: contentViewModel.explorerIconSize,
                                                       maximum: contentViewModel.explorerIconSize * 2))],
                          alignment: .leading) {
                    ForEach(viewModel.result.items) { item in
                        WorkshopItemCell(item: item, isSelected: viewModel.selected?.id == item.id)
                            .onTapGesture { viewModel.selected = item }
                            .contextMenu {
                                Button("Open in Browser") { NSWorkspace.shared.open(item.pageURL) }
                                Button("Copy Link") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(item.pageURL.absoluteString, forType: .string)
                                }
                            }
                            .id(item.id)
                    }
                }
                .padding(.trailing)
            }
            .onChange(of: viewModel.result.currentPage) { _ in
                if let first = viewModel.result.items.first { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
    }

    private var pagination: some View {
        HStack {
            Text("\(viewModel.result.totalCount) wallpapers")
                .foregroundStyle(Color.secondary)
            Spacer()
            Button { viewModel.go(to: 1) } label: { Image(systemName: "chevron.left.2") }
                .disabled(viewModel.page <= 1)
            Button { viewModel.go(to: viewModel.page - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(viewModel.page <= 1)
            Text("Page \(viewModel.page) / \(max(viewModel.result.totalPages, 1))")
                .monospacedDigit()
            Button { viewModel.go(to: viewModel.page + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(viewModel.page >= viewModel.result.totalPages)
            Button { viewModel.go(to: viewModel.result.totalPages) } label: { Image(systemName: "chevron.right.2") }
                .disabled(viewModel.page >= viewModel.result.totalPages)
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Filters

struct WorkshopFilterSidebar: View {
    @ObservedObject var viewModel: WorkshopViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    viewModel.resetFilters()
                } label: {
                    Label("Reset Filters", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                GroupBox("Type") {
                    picker(selection: $viewModel.type, options: WorkshopViewModel.typeTags)
                }
                GroupBox("Age Rating") {
                    picker(selection: $viewModel.rating, options: WorkshopViewModel.ratingTags)
                }
                GroupBox("Resolution") {
                    Picker("", selection: $viewModel.resolution) {
                        Text("All").tag("")
                        ForEach(WorkshopViewModel.resolutionTags, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .onChange(of: viewModel.resolution) { _ in viewModel.reload() }
                }
                DisclosureGroup("Show Only") {
                    toggles(for: WorkshopViewModel.featureTags, in: $viewModel.features)
                }
                DisclosureGroup("Tags") {
                    toggles(for: WorkshopViewModel.genreTags, in: $viewModel.genres)
                }
            }
            .padding(.trailing, 4)
        }
    }

    private func picker(selection: Binding<String>, options: [String]) -> some View {
        Picker("", selection: selection) {
            Text("All").tag("")
            ForEach(options, id: \.self) { Text(LocalizedStringKey($0)).tag($0) }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: selection.wrappedValue) { _ in viewModel.reload() }
    }

    private func toggles(for tags: [String], in set: Binding<Set<String>>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Toggle(LocalizedStringKey(tag), isOn: Binding(
                    get: { set.wrappedValue.contains(tag) },
                    set: { isOn in
                        if isOn { set.wrappedValue.insert(tag) } else { set.wrappedValue.remove(tag) }
                        viewModel.reload()
                    }))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Grid item

struct WorkshopItemCell: View {
    var item: WorkshopItem
    var isSelected: Bool
    @ObservedObject var subscriptions = WorkshopSubscriptions.shared
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .bottom) {
            RemoteAnimatedImage(url: item.thumbnailURL)
                .aspectRatio(1.0, contentMode: .fit)
                .scaleEffect(isHovered ? 1.08 : 1.0)
                .clipped()

            Text(item.title)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30)
                .padding(4)
                .background(Color(white: 0, opacity: isHovered ? 0.5 : 0.35))
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(white: 0.9))
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 4) {
                if let type = item.wallpaperType {
                    Text(LocalizedStringKey(type))
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(WorkshopViewModel.badgeColor(item).opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                if item.tagNames.contains("Approved") {
                    Image(systemName: "trophy.fill").font(.caption2).foregroundStyle(Color.yellow)
                }
                Spacer()
                if subscriptions.isSubscribed(item.publishedfileid) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.white, Color.accentColor)
                }
            }
            .padding(5)
        }
        .border(Color.accentColor, width: isSelected ? 3 : (isHovered ? 1 : 0))
        .animation(.spring(), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Detail panel

struct WorkshopDetail: View {
    @ObservedObject var viewModel: WorkshopViewModel
    var wallpaperViewModel: WallpaperViewModel

    var body: some View {
        if let item = viewModel.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    RemoteAnimatedImage(url: item.previewURL)
                        .aspectRatio(1.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text(item.title).font(.title2.bold())
                    Text("by \(viewModel.author(of: item))").foregroundStyle(Color.secondary)

                    HStack(spacing: 2) {
                        ForEach(0..<5) { index in
                            Image(systemName: index < (item.star_rating ?? 0) ? "star.fill" : "star")
                                .foregroundStyle(Color.yellow)
                        }
                        if let votes = item.total_votes { Text("(\(votes))").foregroundStyle(Color.secondary) }
                    }

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        row("Type", item.wallpaperType ?? "-")
                        row("Rating", item.contentRating ?? "-")
                        row("Size", ByteCountFormatter.string(fromByteCount: item.sizeInBytes, countStyle: .file))
                        row("Subscribers", (item.subscriptions ?? 0).formatted())
                        row("Favorites", (item.favorited ?? 0).formatted())
                        if let updated = item.time_updated {
                            row("Updated", Date(timeIntervalSince1970: TimeInterval(updated)).formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                    .font(.callout)

                    if item.wallpaperType == "Scene" {
                        Label("Scenes on Mac: images, animations, texts and sounds are shown; particles, 3D and shader effects not yet.",
                              systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(Color.orange)
                    } else if !WorkshopViewModel.playsOnMac(item) {
                        Label("This type is not supported on Mac yet.", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(Color.orange)
                    }

                    WorkshopSubscribeButton(item: item, wallpaperViewModel: wallpaperViewModel)
                    Button {
                        NSWorkspace.shared.open(item.pageURL)
                    } label: {
                        Label("Open in Browser", systemImage: "safari").frame(maxWidth: .infinity)
                    }

                    if let description = item.short_description, !description.isEmpty {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(Color.secondary)
                            .textSelection(.enabled)
                    }

                    FlowTags(tags: item.tagNames.filter { $0 != "Wallpaper" })
                }
                .padding()
            }
        } else {
            VStack {
                Spacer()
                Text("Please select a wallpaper")
                    .font(.title3)
                    .foregroundStyle(Color.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(Color.secondary)
            Text(value)
        }
    }
}

/// Subscribing goes through the Steam client running in Wine (see SteamWorkshopBridge)
struct WorkshopSubscribeButton: View {
    var item: WorkshopItem
    var wallpaperViewModel: WallpaperViewModel
    @ObservedObject var subscriptions = WorkshopSubscriptions.shared

    var body: some View {
        let id = item.publishedfileid
        let state = subscriptions.states[id]
        VStack(spacing: 8) {
            if subscriptions.busy.contains(id), state?.isInstalled != true {
                if let state, state.total > 0 {
                    ProgressView(value: state.progress) {
                        Text("Downloading \(Int(state.progress * 100)) %")
                    }
                } else {
                    ProgressView { Text("Waiting for Steam…") }
                }
            } else if state?.isSubscribed == true {
                if state?.isInstalled == true, WorkshopViewModel.playsOnMac(item) {
                    Button {
                        apply(id)
                    } label: {
                        Label("Use as Wallpaper", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(role: .destructive) {
                    subscriptions.unsubscribe(id)
                } label: {
                    Label("Unsubscribe", systemImage: "minus.circle").frame(maxWidth: .infinity)
                }
            } else {
                Button {
                    subscriptions.subscribe(id)
                } label: {
                    Label("Subscribe", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            if let message = subscriptions.errorMessage {
                Text(message).font(.caption).foregroundStyle(Color.red)
            }
        }
    }

    private func apply(_ id: String) {
        let directory = WallpaperLibrary.directory(ofWorkshopItem: id)
        guard let data = try? Data(contentsOf: directory.appending(path: "project.json")),
              let project = try? JSONDecoder().decode(WEProject.self, from: data)
        else { return }
        wallpaperViewModel.nextCurrentWallpaper = WEWallpaper(using: project, where: directory)
    }
}

struct FlowTags: View {
    var tags: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Text(LocalizedStringKey(tag))
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - Remote (animated) preview

/// Loads a remote GIF/JPEG/PNG off the main thread and keeps GIFs animated
struct RemoteAnimatedImage: NSViewRepresentable {
    var url: URL?

    private static let cache = NSCache<NSURL, NSImage>()

    final class Coordinator {
        var url: URL?
        var task: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.canDrawSubviewsIntoLayer = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        context.coordinator.task?.cancel()
        view.image = nil
        guard let url else { return }
        if let cached = Self.cache.object(forKey: url as NSURL) {
            view.image = cached
            return
        }
        context.coordinator.task = Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled,
                  let image = NSImage(data: data)
            else { return }
            Self.cache.setObject(image, forKey: url as NSURL)
            await MainActor.run { view.image = image }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: proposal.height ?? width)
    }
}
