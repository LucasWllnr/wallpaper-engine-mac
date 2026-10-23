//
//  Checks/main.swift — end-to-end checks for Open Wallpaper Engine (no Xcode test target needed)
//
//  Build and run with tools/run-checks.sh. Sections:
//    api      Steam Workshop search/sort/filters/paging/details
//    steam    Steam for Mac bridge (wehelper-mac)
//    library  installed wallpapers and their project.json
//    scenes   every local scene builds
//    visual   scenes rendered in a real window and captured (not blank, animated, 3D, particles)
//

import AppKit
import SceneKit

// these checks cover the built-in renderer; the faithful engine is checked by tools/lwe-shots.sh
UserDefaults.standard.set(false, forKey: "UseFaithfulRenderer")

var failures = 0, passes = 0
let outputDirectory = URL(filePath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Checks/output")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let sections = Set(CommandLine.arguments.dropFirst(2))
func enabled(_ name: String) -> Bool { sections.isEmpty || sections.contains(name) }

func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if condition { passes += 1; print("  ✓", message()) } else { failures += 1; print("  ✗", message()) }
}

// MARK: - API

@MainActor func checkAPI() async {
    print("\n== API Steam Workshop")
    let service = WorkshopService.shared
    do {
        let trending = try await service.search(WorkshopQuery(sort: .trendWeek, requiredTags: ["Everyone"]))
        check(trending.items.count == 30, "tendances : 30 résultats par page (\(trending.items.count))")
        check(trending.totalCount > 1000, "tendances : total plausible (\(trending.totalCount))")
        check(trending.items.allSatisfy { !$0.title.isEmpty && $0.previewURL != nil }, "chaque résultat a un titre et un aperçu")
        check(trending.items.allSatisfy { $0.tagNames.contains("Everyone") }, "filtre « Everyone » respecté")
        check(!trending.authors.isEmpty, "noms d'auteurs récupérés (\(trending.authors.count))")

        let videos = try await service.search(WorkshopQuery(sort: .topRated, requiredTags: ["Video", "Everyone"], page: 2))
        check(videos.currentPage == 2, "pagination : page 2 demandée, page \(videos.currentPage) reçue")
        check(videos.items.allSatisfy { $0.wallpaperType == "Video" }, "filtre de type Vidéo respecté")

        let search = try await service.search(WorkshopQuery(searchText: "bonfire"))
        check(search.items.contains { $0.title.localizedCaseInsensitiveContains("bonfire") }, "recherche « bonfire » pertinente")

        let details = try await service.details(of: ["2325500626"])
        check(details.first?.title == "Dark Souls Bonfire (Pixel)", "détails d'un fond : \(details.first?.title ?? "aucun")")
        check((details.first?.sizeInBytes ?? 0) > 1_000_000, "taille du fond renseignée")

        if let preview = trending.items.first?.thumbnailURL {
            let (data, _) = try await URLSession.shared.data(from: preview)
            check(NSImage(data: data) != nil, "vignette réduite téléchargeable (\(data.count / 1024) Ko)")
        }
    } catch {
        check(false, "API : \(error.localizedDescription)")
    }
}

// MARK: - Steam

func checkSteam() async {
    print("\n== Steam pour Mac")
    let helper = URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "wehelper-mac")
    check(FileManager.default.isExecutableFile(atPath: helper.path(percentEncoded: false)), "wehelper-mac présent")
    let process = Process()
    process.executableURL = helper
    process.arguments = ["status", "2325500626"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        let line = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let state = try? JSONDecoder().decode(WorkshopItemState.self, from: Data(line.utf8))
        check(state != nil, "réponse JSON de Steam : \(line.prefix(80))")
        check(state?.isSubscribed == true, "abonnement de test reconnu par Steam Mac")
    } catch {
        check(false, "wehelper-mac : \(error)")
    }
}

// MARK: - Library

func checkLibrary() -> [WEWallpaper] {
    print("\n== Bibliothèque")
    let urls = WallpaperLibrary.wallpaperURLs
    check(!urls.isEmpty, "fonds installés trouvés (\(urls.count))")
    var wallpapers = [WEWallpaper]()
    var unreadable = [String]()
    for url in urls {
        guard let data = try? Data(contentsOf: url.appending(path: "project.json")) else { unreadable.append(url.lastPathComponent); continue }
        guard let project = try? JSONDecoder().decode(WEProject.self, from: data) else {
            // Presets reuse another wallpaper ("dependency") and have no file of their own
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if json?["dependency"] == nil { unreadable.append(url.lastPathComponent) }
            continue
        }
        wallpapers.append(WEWallpaper(using: project, where: url))
    }
    check(unreadable.isEmpty, "project.json lisibles (\(unreadable.count) illisibles : \(unreadable.prefix(5)))")
    let types = Dictionary(grouping: wallpapers, by: { $0.project.type.lowercased() }).mapValues(\.count)
    print("    types :", types)
    let videos = wallpapers.filter { $0.project.type.lowercased() == "video" }
    let missing = videos.filter { !FileManager.default.fileExists(atPath: $0.wallpaperDirectory.appending(path: $0.project.file).path(percentEncoded: false)) }
    check(missing.isEmpty, "fichiers vidéo présents (\(missing.count) manquants)")
    check(WallpaperLibrary.workshopID(of: WallpaperLibrary.importDirectory.appending(path: "123")) == nil
          && WallpaperLibrary.workshopID(of: WallpaperLibrary.macWorkshopDirectory.appending(path: "123")) == "123",
          "fonds importés / abonnements de l'Atelier distingués")
    // presets: only the properties the wallpaper declares are loaded, {"value": …} wrappers accepted
    if let target = urls.first(where: { WallpaperProperties.list(for: $0).contains { $0.kind == .bool } }),
       let key = WallpaperProperties.list(for: target).first(where: { $0.kind == .bool })?.key {
        WallpaperProperties.load(preset: Data(#"{"\#(key)": {"value": true}, "not_a_property": 1}"#.utf8), into: target)
        let saved = (try? JSONSerialization.jsonObject(with: WallpaperProperties.preset(of: target))) as? [String: Any]
        check(saved?[key] as? Bool == true && saved?["not_a_property"] == nil, "preset chargé puis enregistré (\(key))")
        WallpaperProperties.reset(target)
    }
    // playlist: in order it wraps around, shuffled it never repeats the current wallpaper
    check(Playlist.nextIndex(after: 2, count: 3, shuffle: false) == 0 && Playlist.nextIndex(after: nil, count: 3, shuffle: false) == 0
          && (0..<20).allSatisfy { _ in Playlist.nextIndex(after: 1, count: 3, shuffle: true) != 1 }
          && Playlist.nextIndex(after: nil, count: 0, shuffle: true) == nil, "playlist : fond suivant")
    // Installed tab: search and sort over the cached library
    let library = ContentViewModel()
    if let sample = library.allWallpapers.first(where: { $0.project.title.count > 3 }) {
        library.searchText = String(sample.project.title.prefix(4)).uppercased()
        check(library.autoRefreshWallpapers.contains { $0.wallpaperDirectory == sample.wallpaperDirectory }
              && library.autoRefreshWallpapers.allSatisfy { ($0.project.title + ($0.project.tags ?? []).joined()).localizedCaseInsensitiveContains(library.searchText) },
              "recherche dans la bibliothèque (\(library.searchText))")
        library.searchText = ""
    }
    let sortedTitles = library.autoRefreshWallpapers.map(\.project.title)
    check(library.sortingBy != .name || sortedTitles == sortedTitles.sorted { $0.localizedStandardCompare($1) == (library.sortingSequence == .increased ? .orderedAscending : .orderedDescending) }
          || sortedTitles.count < 2, "tri par nom")
    return wallpapers
}

// MARK: - Scenes

func checkScenes(_ wallpapers: [WEWallpaper]) -> [(WEWallpaper, SceneDescription)] {
    print("\n== Scènes")
    var built = [(WEWallpaper, SceneDescription)]()
    for wallpaper in wallpapers where wallpaper.project.type.lowercased() == "scene" {
        do {
            let scene = try SceneBuilder.build(directory: wallpaper.wallpaperDirectory, sceneFile: wallpaper.project.file)
            built.append((wallpaper, scene))
        } catch {
            check(false, "\(wallpaper.project.title) : \(error.localizedDescription)")
        }
    }
    let total = wallpapers.filter { $0.project.type.lowercased() == "scene" }.count
    check(built.count == total, "scènes construites : \(built.count)/\(total)")
    let particles = built.flatMap(\.1.nodes).filter { if case .particles = $0.content { return true }; return false }.count
    let effects = built.flatMap(\.1.nodes).flatMap(\.effects).count
    let threeD = built.filter { $0.1.threeD != nil }.count
    check(particles > 0, "systèmes de particules reconnus : \(particles)")
    check(effects > 0, "effets reconnus : \(effects)")
    print("    scènes 3D : \(threeD)")
    return built
}

// MARK: - Visual

struct ImageStats {
    var mean = 0.0, deviation = 0.0, white = 0.0, black = 0.0
}

func stats(_ image: CGImage) -> ImageStats {
    let width = 160, height = 90
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var values = [Double]()
    for i in stride(from: 0, to: pixels.count, by: 4) {
        values.append((Double(pixels[i]) + Double(pixels[i + 1]) + Double(pixels[i + 2])) / 765)
    }
    var s = ImageStats()
    s.mean = values.reduce(0, +) / Double(values.count)
    s.deviation = sqrt(values.map { ($0 - s.mean) * ($0 - s.mean) }.reduce(0, +) / Double(values.count))
    s.white = Double(values.filter { $0 > 0.97 }.count) / Double(values.count)
    s.black = Double(values.filter { $0 < 0.02 }.count) / Double(values.count)
    return s
}

var previewReport = [(id: String, title: String, distance: Double, brightness: Double, moving: Double)]()

/// Mean RGB of the center square (previews are usually square, captures 16:9)
func averageColor(_ image: CGImage) -> (Double, Double, Double) {
    let side = min(image.width, image.height)
    let crop = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)) ?? image
    var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
    let context = CGContext(data: &pixels, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(crop, in: CGRect(x: 0, y: 0, width: 32, height: 32))
    var sum = (0.0, 0.0, 0.0)
    for i in stride(from: 0, to: pixels.count, by: 4) {
        sum.0 += Double(pixels[i]); sum.1 += Double(pixels[i + 1]); sum.2 += Double(pixels[i + 2])
    }
    let n = Double(32 * 32) * 255
    return (sum.0 / n, sum.1 / n, sum.2 / n)
}

func difference(_ a: CGImage, _ b: CGImage) -> Double {
    let width = 160, height = 90
    func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }
    let pa = pixels(a), pb = pixels(b)
    return zip(pa, pb).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(pa.count) / 255
}

/// Captures a window through WindowServer, so particles, filters and SceneKit are included
func capture(_ window: NSWindow) -> CGImage? {
    let file = FileManager.default.temporaryDirectory.appending(path: "owe-check-\(UUID().uuidString).png")
    // This tool is an AppKit app with its own (absent) Screen Recording permission, so the
    // calling shell (run-checks.sh) takes the screenshot of the window's region for it
    let screenHeight = window.screen?.frame.height ?? NSScreen.main?.frame.height ?? 900
    let frame = window.frame
    let region = "\(Int(frame.minX)),\(Int(screenHeight - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
    print("OWE_CAPTURE \(region) \(file.path(percentEncoded: false))")
    fflush(stdout)
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    // Read the bytes before deleting the file: CGImageSource decodes lazily
    guard let data = try? Data(contentsOf: file),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    else { return nil }
    try? FileManager.default.removeItem(at: file)
    return image
}

func save(_ image: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: outputDirectory.appending(path: name))
}

@MainActor func checkVisual(_ scenes: [(WEWallpaper, SceneDescription)]) async {
    print("\n== Visuel (fenêtre réelle, capturée par WindowServer)")
    let window = NSWindow(contentRect: NSRect(x: 0, y: (NSScreen.main?.frame.height ?? 900) - 400, width: 640, height: 360),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.level = .statusBar
    window.isReleasedWhenClosed = false
    // Visible on every Space, including over full-screen apps, so the capture sees it
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

    // Control: a plain red view must come out red, otherwise the capture itself is broken
    let control = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    control.wantsLayer = true
    control.layer?.backgroundColor = NSColor.red.cgColor
    window.contentView = control
    window.orderFrontRegardless()
    try? await Task.sleep(for: .seconds(1))
    if let image = capture(window) {
        save(image, "control.png")
        check(stats(image).mean > 0.2, "témoin rouge capturé (moyenne \(String(format: "%.2f", stats(image).mean)))")
    } else {
        check(false, "témoin : capture impossible")
    }
    // Representative scenes: plain, sprites, particles, effects, 3D
    var picked = [(WEWallpaper, SceneDescription)]()
    func pick(_ predicate: (SceneDescription) -> Bool, _ count: Int) {
        for item in scenes where predicate(item.1) && !picked.contains(where: { $0.0.wallpaperDirectory == item.0.wallpaperDirectory }) {
            picked.append(item)
            if picked.filter({ predicate($0.1) }).count >= count { break }
        }
    }
    let hasParticles = { (s: SceneDescription) in s.nodes.contains { if case .particles = $0.content { return true }; return false } }
    pick({ $0.threeD != nil }, 2)
    pick(hasParticles, 3)
    pick({ !$0.nodes.flatMap(\.effects).isEmpty }, 3)
    pick({ $0.nodes.contains { if case .animation = $0.content { return true }; return false } }, 1)
    if ProcessInfo.processInfo.environment["OWE_CHECK_ALL"] != nil { picked = scenes }
    if let only = ProcessInfo.processInfo.environment["OWE_CHECK_IDS"] {
        let ids = Set(only.split(separator: ","))
        picked = scenes.filter { ids.contains(Substring($0.0.wallpaperDirectory.lastPathComponent)) }
    }

    for (wallpaper, scene) in picked {
        let id = wallpaper.wallpaperDirectory.lastPathComponent
        let view = SceneLayerView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        window.contentView = view
        window.orderFrontRegardless()
        view.setPlaying(true, volume: 0)
        view.load(wallpaper)
        // Heavy scenes (4K textures, baked blurs) take a while: wait for the layers, then let them settle
        let start = Date()
        while !view.isLoaded && Date().timeIntervalSince(start) < 20 { try? await Task.sleep(for: .milliseconds(200)) }
        check(view.isLoaded, "\(wallpaper.project.title) : chargée en \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        try? await Task.sleep(for: .seconds(2))
        if ProcessInfo.processInfo.environment["OWE_DEBUG"] != nil, let scene = view.layer?.sublayers?.first {
            print("    scène: frame \(scene.frame) bounds \(scene.bounds) échelle \(scene.transform.m11)")
            for child in (scene.sublayers ?? []).prefix(4) {
                print("      calque: frame \(child.frame) position \(child.position) bounds \(child.bounds.size) contenu \(child.contents != nil)")
            }
        }
        guard let first = capture(window) else { check(false, "\(wallpaper.project.title) : capture impossible (autorisation Enregistrement de l'écran ?)"); continue }
        try? await Task.sleep(for: .milliseconds(800))
        let second = capture(window) ?? first
        save(first, "\(id)-a.png"); save(second, "\(id)-b.png")
        let s = stats(first)
        let moving = difference(first, second)
        // Compare with the workshop preview: overall brightness and average color
        if let previewURL = ["preview.jpg", "preview.gif", "preview.png"].map({ wallpaper.wallpaperDirectory.appending(path: $0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }),
           let source = CGImageSourceCreateWithURL(previewURL as CFURL, nil),
           let preview = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let a = averageColor(first), b = averageColor(preview)
            let brightness = (a.0 + a.1 + a.2) / 3 - (b.0 + b.1 + b.2) / 3
            let distance = sqrt(pow(a.0 - b.0, 2) + pow(a.1 - b.1, 2) + pow(a.2 - b.2, 2))
            previewReport.append((id, wallpaper.project.title, distance, brightness, moving))
            check(distance < 0.25, "\(wallpaper.project.title) : couleurs proches de l'aperçu (écart \(String(format: "%.2f", distance)), luminosité \(String(format: "%+.2f", brightness)))")
        }
        let kinds = [scene.threeD != nil ? "3D" : nil, hasParticles(scene) ? "particules" : nil,
                     scene.nodes.flatMap(\.effects).isEmpty ? nil : "effets"].compactMap { $0 }.joined(separator: "+")
        print("  • \(id) \(wallpaper.project.title) [\(kinds)] moyenne \(String(format: "%.2f", s.mean)) contraste \(String(format: "%.3f", s.deviation)) blanc \(Int(s.white * 100))% noir \(Int(s.black * 100))% mouvement \(String(format: "%.4f", moving))")
        check(s.deviation > 0.01, "\(wallpaper.project.title) : image non uniforme")
        check(s.white < 0.6, "\(wallpaper.project.title) : pas saturée en blanc")
        check(s.black < 0.85, "\(wallpaper.project.title) : pas noire")
        if hasParticles(scene) || !scene.nodes.flatMap(\.effects).isEmpty {
            check(moving > 0.0005, "\(wallpaper.project.title) : animation visible entre deux captures")
        }
    }
    window.orderOut(nil)
    if !previewReport.isEmpty {
        print("\n== Les plus éloignés de leur aperçu")
        for row in previewReport.sorted(by: { $0.distance > $1.distance }).prefix(15) {
            print(String(format: "  %@ %@ — écart %.2f, luminosité %+.2f, mouvement %.4f", row.id, String(row.title.prefix(40)), row.distance, row.brightness, row.moving))
        }
    }
}

// MARK: - Run

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    if enabled("api") { await checkAPI() }
    if enabled("steam") { await checkSteam() }
    let wallpapers = enabled("library") || enabled("scenes") || enabled("visual") ? checkLibrary() : []
    let scenes = enabled("scenes") || enabled("visual") ? checkScenes(wallpapers) : []
    if enabled("visual") { await checkVisual(scenes) }
    print("\n\(passes) réussis, \(failures) échoués — captures dans \(outputDirectory.path(percentEncoded: false))")
    exit(failures == 0 ? 0 : 1)
}
app.run()
