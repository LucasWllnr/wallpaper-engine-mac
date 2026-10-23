//
//  SceneWallpaperView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/13.
//
//  Renders Wallpaper Engine "scene" wallpapers with Core Animation: image layers
//  (static and sprite sheets), text layers driven by their SceneScript (JavaScriptCore)
//  and looping sounds. Particles, puppet warp animation and shader effects are not
//  rendered yet; their base image is shown instead.
//

import AVFoundation
import CoreImage
import CoreText
import JavaScriptCore
import SwiftUI

struct SceneWallpaperView: NSViewRepresentable {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel

    func makeNSView(context: Context) -> SceneLayerView {
        let view = SceneLayerView()
        view.load(wallpaperViewModel.currentWallpaper)
        return view
    }

    func updateNSView(_ view: SceneLayerView, context: Context) {
        let wallpaper = wallpaperViewModel.currentWallpaper
        if view.loadedDirectory != wallpaper.wallpaperDirectory {
            view.load(wallpaper)
        }
        view.setPlaying(wallpaperViewModel.playRate != 0, volume: wallpaperViewModel.playVolume)
    }
}

// MARK: - Scene description (built off the main thread)

struct SceneDescription {
    struct Node {
        enum Content {
            case image(CGImage)
            case animation([(CGImage, Double)])
            case text(SceneText)
            case particles(SceneParticleSystem)
            case none
        }
        var id: Int
        var parent: Int?
        var origin: CGPoint
        var size: CGSize
        var scale: CGSize
        var rotation: CGFloat
        var alpha: Float
        var additive: Bool
        var content: Content
        var effects = [SceneEffect]()
        /// How much the layer follows the cursor when camera parallax is on
        var parallaxDepth = CGSize(width: 1, height: 1)
    }

    struct SceneText {
        var value: String
        var script: String?
        var font: CTFont
        var color: CGColor
        var alignment: CATextLayerAlignmentMode
    }

    var size = CGSize(width: 1920, height: 1080)
    var background = CGColor(gray: 0, alpha: 1)
    var nodes = [Node]()
    var sounds = [(data: Data, volume: Float)]()
    /// Camera parallax (layers move with the cursor by their depth); 0 = off
    var parallaxAmount: Double = 0
    /// Models, lights and groups of perspective (3D) scenes, drawn below the 2D layers
    var threeD: SceneThreeD?
}

enum SceneBuilder {
    /// The wallpaper's property values while a scene is being built, for {"user": …} bindings
    private static var userValues = [String: Any]()

    static func build(directory: URL, sceneFile: String) throws -> SceneDescription {
        userValues = WallpaperProperties.values(for: directory)
        let package = try WEScenePackage(directory: directory, sceneFile: sceneFile)
        guard let scene = package.json(sceneFile) ?? package.json("scene.json") else { throw WESceneError.badPackage }
        var result = SceneDescription()

        let general = scene["general"] as? [String: Any] ?? [:]
        if let projection = general["orthogonalprojection"] as? [String: Any],
           let width = number(projection["width"]), let height = number(projection["height"]), width > 0, height > 0 {
            result.size = CGSize(width: width, height: height)
        }
        if let clear = vector(general["clearcolor"]), clear.count >= 3 {
            result.background = CGColor(red: clear[0], green: clear[1], blue: clear[2], alpha: 1)
        }

        if bool(general["cameraparallax"]) ?? false {
            result.parallaxAmount = number(general["cameraparallaxamount"]) ?? 0.5
        }

        // Perspective scenes carry 3D models; their camera comes from "camera" + general fov
        let isPerspective = !(general["orthogonalprojection"] is [String: Any])
        var threeD = SceneThreeD()
        if let camera = scene["camera"] as? [String: Any] {
            threeD.eye = vector(camera["eye"]) ?? threeD.eye
            threeD.center = vector(camera["center"]) ?? threeD.center
            threeD.up = vector(camera["up"]) ?? threeD.up
        }
        threeD.fov = number(general["fov"]) ?? threeD.fov
        threeD.near = number(general["nearz"]) ?? threeD.near
        threeD.far = number(general["farz"]) ?? threeD.far
        threeD.ambient = vector(general["ambientcolor"]) ?? threeD.ambient

        var fonts = [String: CGDataProvider]()
        var textures = [String: WETexture?]()
        /// "name" -> materials/name.tex, from the scene or Wallpaper Engine's assets (cached)
        func texture(_ name: String) -> WETexture? {
            let path = "materials/\(name).tex"
            if let cached = textures[path] { return cached }
            let decoded = package.data(path).flatMap { try? WETexture.decode($0, name: name) }
            textures[path] = decoded
            return decoded
        }

        for object in scene["objects"] as? [[String: Any]] ?? [] {
            guard bool(object["visible"]) ?? true, let id = number(object["id"]).map(Int.init) else { continue }
            let origin = vector(object["origin"]) ?? [0, 0, 0]
            let scale = vector(object["scale"]) ?? [1, 1, 1]
            let angles = vector(object["angles"]) ?? [0, 0, 0]
            let color = vector(object["color"]) ?? [1, 1, 1]
            var node = SceneDescription.Node(
                id: id,
                parent: number(object["parent"]).map(Int.init),
                origin: CGPoint(x: origin[safe: 0] ?? 0, y: origin[safe: 1] ?? 0),
                size: vector(object["size"]).map { CGSize(width: $0[safe: 0] ?? 0, height: $0[safe: 1] ?? 0) } ?? .zero,
                scale: CGSize(width: scale[safe: 0] ?? 1, height: scale[safe: 1] ?? 1),
                rotation: angles[safe: 2] ?? 0,
                alpha: Float(number(object["alpha"]) ?? 1),
                additive: false,
                content: .none)
            if let depth = vector(object["parallaxDepth"]), depth.count >= 2 {
                node.parallaxDepth = CGSize(width: depth[0], height: depth[1])
            }

            // 3D: models, lights and the groups that hold them
            if isPerspective, object["image"] as? String == nil, object["particle"] as? String == nil,
               object["text"] == nil, object["sound"] == nil {
                var item = SceneThreeD.Object(id: id, parent: node.parent, origin: origin, angles: angles, scale: scale)
                if let modelPath = object["model"] as? String, let data = package.data(modelPath) {
                    item.meshes = SceneThreeD.readModel(data, package: package, texture: texture)
                }
                if let kind = object["light"] as? String {
                    item.light = (kind, color, number(object["intensity"]) ?? 1, number(object["radius"]) ?? 10)
                }
                // A camera left at the origin is driven by an animated bone: keep the default camera then
                if object["camera"] is String, threeD.cameraObject == nil, (origin + angles).contains(where: { abs($0) > 0.0001 }) {
                    threeD.cameraObject = (origin, angles)
                    threeD.fov = number(object["fov"]) ?? threeD.fov
                }
                threeD.objects.append(item)
                continue
            }

            if let particlePath = object["particle"] as? String {
                let override = object["instanceoverride"] as? [String: Any] ?? [:]
                if let system = SceneParticleSystem.load(particlePath, override: override, package: package, texture: texture) {
                    node.content = .particles(system)
                }
            } else if let imagePath = object["image"] as? String, imagePath.hasSuffix("solidlayer.json") {
                // Built-in solid color rectangle: drawn only as a background (below every image);
                // above images it is a blend/effect host that a flat fill would cover entirely
                let hasImageBelow = result.nodes.contains { if case .image = $0.content { return true }; if case .animation = $0.content { return true }; return false }
                guard !hasImageBelow, (object["effects"] as? [Any] ?? []).isEmpty else { result.nodes.append(node); continue }
                let fill = CGColor(srgbRed: color[safe: 0] ?? 1, green: color[safe: 1] ?? 1, blue: color[safe: 2] ?? 1, alpha: 1)
                if let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    context.setFillColor(fill)
                    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
                    if let image = context.makeImage() { node.content = .image(image) }
                }
                if node.size == .zero { node.size = result.size }
            } else if let imagePath = object["image"] as? String {
                // Effect layers (compose/fullscreen/project) only make sense with shaders
                guard let model = package.json(imagePath), !(bool(model["fullscreen"]) ?? false),
                      !(bool(model["passthrough"]) ?? false),
                      let materialPath = model["material"] as? String,
                      let material = package.json(materialPath),
                      let pass = (material["passes"] as? [[String: Any]])?.first,
                      let textureName = (pass["textures"] as? [Any])?.first as? String
                else { result.nodes.append(node); continue }
                node.additive = (pass["blending"] as? String) == "additive"
                node.effects = (object["effects"] as? [[String: Any]] ?? []).compactMap {
                    SceneEffect.load($0, package: package, texture: texture)
                }

                if let texture = texture(textureName) {
                    let tint = color.count >= 3 && color.prefix(3).contains { abs($0 - 1) > 0.01 } ? Array(color.prefix(3)) : nil
                    let animation = texture.animation
                    if animation.count > 1 {
                        node.content = .animation(animation.map { (Self.tinted($0.0, tint), $0.1) })
                        if node.size == .zero { node.size = CGSize(width: animation[0].0.width, height: animation[0].0.height) }
                    } else if let image = texture.croppedImage {
                        node.content = .image(Self.tinted(image, tint))
                        if node.size == .zero { node.size = texture.imageSize }
                    }
                }
            } else if let text = object["text"] {
                let value = (text as? [String: Any])?["value"] as? String ?? text as? String ?? ""
                let script = (text as? [String: Any])?["script"] as? String
                let pointSize = number(object["pointsize"]) ?? 32
                var font = CTFontCreateWithName("Helvetica Neue" as CFString, pointSize, nil)
                if let fontPath = object["font"] as? String, let data = package.data(fontPath) {
                    if fonts[fontPath] == nil { fonts[fontPath] = CGDataProvider(data: data as CFData) }
                    if let provider = fonts[fontPath], let cgFont = CGFont(provider) {
                        font = CTFontCreateWithGraphicsFont(cgFont, pointSize, nil, nil)
                    }
                }
                let alignment: CATextLayerAlignmentMode = switch object["horizontalalign"] as? String {
                case "left": .left
                case "right": .right
                default: .center
                }
                node.content = .text(SceneDescription.SceneText(
                    value: value, script: script, font: font,
                    color: CGColor(red: color[safe: 0] ?? 1, green: color[safe: 1] ?? 1, blue: color[safe: 2] ?? 1, alpha: 1),
                    alignment: alignment))
            } else if let sounds = object["sound"] as? [String] {
                let volume = Float(number(object["volume"]) ?? 1)
                if let first = sounds.first, let data = package.data(first) {
                    result.sounds.append((data, volume))
                }
                continue
            }
            result.nodes.append(node)
        }
        if threeD.hasContent { result.threeD = threeD }
        return result
    }

    // MARK: Value helpers (values may be wrapped as {"value": …, "user": …})

    private static func unwrap(_ any: Any?) -> Any? {
        guard let dictionary = any as? [String: Any], dictionary["value"] != nil else { return any }
        // bound to a user property: plain name, or {"name", "condition"} which compares the value
        switch dictionary["user"] {
        case let name as String:
            if let value = userValues[name] { return value }
        case let binding as [String: Any]:
            if let name = binding["name"] as? String, let value = userValues[name] {
                return WallpaperProperties.stringValue(value) == WallpaperProperties.stringValue(binding["condition"])
            }
        default: break
        }
        return dictionary["value"]
    }

    static func number(_ any: Any?) -> Double? {
        switch unwrap(any) {
        case let value as NSNumber: value.doubleValue
        case let value as String: Double(value)
        default: nil
        }
    }

    static func bool(_ any: Any?) -> Bool? {
        switch unwrap(any) {
        case let value as Bool: value
        case let value as NSNumber: value.boolValue
        default: nil
        }
    }

    static func vector(_ any: Any?) -> [Double]? {
        switch unwrap(any) {
        case let value as String: value.split(separator: " ").compactMap { Double($0) }
        case let value as NSNumber: [value.doubleValue]
        default: nil
        }
    }

    private static func tinted(_ image: CGImage, _ color: [Double]?) -> CGImage {
        guard let color else { return image }
        let filter = CIFilter(name: "CIColorMatrix")!
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: color[0], y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: color[1], z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: color[2], w: 0), forKey: "inputBVector")
        guard let output = filter.outputImage,
              let tinted = CIContext().createCGImage(output, from: output.extent)
        else { return image }
        return tinted
    }
}


// MARK: - SceneScript (text layers)

/// Runs Wallpaper Engine text scripts (`update(value)`) with a minimal engine API
final class SceneScriptRunner {
    private let context = JSContext()!
    private let hasUpdate: Bool

    init?(script: String) {
        context.exceptionHandler = { _, _ in }
        context.evaluateScript("""
        var engine = { frametime: 1, runtime: 0, timeOfDay: 0, screenResolution: { x: 1920, y: 1080 },
                       isDesktopDevice: function () { return true; }, isRunningInEditor: function () { return false; },
                       isWallpaper: function () { return true; } };
        var input = { cursorWorldPosition: { x: 0, y: 0 } };
        var shared = {};
        var localStorage = { get: function () { return undefined; }, set: function () {} };
        function createScriptProperties() {
            var properties = {};
            var builder = {};
            ['addCheckbox', 'addSlider', 'addText', 'addColor', 'addCombo', 'addFile', 'addDirectory', 'addTextInput']
                .forEach(function (name) {
                    builder[name] = function (option) {
                        var value = option.value;
                        if (value === undefined && option.options && option.options.length) value = option.options[0].value;
                        properties[option.name] = value;
                        return builder;
                    };
                });
            builder.finish = function () { return properties; };
            return builder;
        }
        """)
        // ES module syntax is not available in a plain context
        let source = script.replacingOccurrences(of: #"(?m)^\s*export\s+(default\s+)?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*import\s.*$"#, with: "", options: .regularExpression)
        context.evaluateScript(source)
        guard context.exception == nil else { return nil }
        hasUpdate = context.objectForKeyedSubscript("update")?.isUndefined == false
        guard hasUpdate else { return nil }
    }

    func update(_ value: String) -> String? {
        context.evaluateScript("engine.runtime += 1;")
        guard let result = context.objectForKeyedSubscript("update").call(withArguments: [value]),
              context.exception == nil, !result.isUndefined, !result.isNull
        else { context.exception = nil; return nil }
        return result.toString()
    }
}

// MARK: - Layer view

final class SceneLayerView: NSView {
    private(set) var loadedDirectory: URL?
    /// True once the scene is built and its layers are in place
    private(set) var isLoaded = false
    private let sceneLayer = CALayer()
    private var sceneSize = CGSize(width: 1920, height: 1080)
    private var players = [AVAudioPlayer]()
    private var textUpdaters = [(layer: CATextLayer, runner: SceneScriptRunner, value: String)]()
    private var timer: Timer?
    private var volume: Float = 1
    private var playing = true
    private var parallaxAmount = 0.0
    private var parallaxLayers = [(layer: CALayer, base: CGPoint, depth: CGSize)]()
    private var parallaxTimer: Timer?
    private var cursor = CGPoint(x: 0.5, y: 0.5)
    /// Faithful renderer (real shaders); the Core Animation scene below is its fallback
    private var engine: FaithfulSceneEngine?
    private var propertiesObserver: NSObjectProtocol?
    private var pendingReload: DispatchWorkItem?
    private var loadedWallpaper: WEWallpaper?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-hosting view: assign the layer before turning wantsLayer on, otherwise AppKit
        // treats it as layer-backed and manages (and can blank) the layer tree itself
        let root = CALayer()
        root.backgroundColor = .black
        root.addSublayer(sceneLayer)
        layer = root
        wantsLayer = true
        // Effects use Core Image filters on layers
        layerUsesCoreImageFilters = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func load(_ wallpaper: WEWallpaper) {
        loadedWallpaper = wallpaper
        loadedDirectory = wallpaper.wallpaperDirectory
        observeProperties(of: wallpaper)
        isLoaded = false
        engine?.stop()
        engine = nil
        let faithful = FaithfulSceneEngine()
        faithful.onFailure = { [weak self] in
            // unsupported scene or crash: show the built-in equivalent instead
            guard let self, self.engine === faithful else { return }
            self.engine = nil
            self.buildFallback(wallpaper)
        }
        if faithful.start(directory: wallpaper.wallpaperDirectory, screen: window?.screen, volume: volume) {
            engine = faithful
            faithful.setPaused(!playing)
            isLoaded = true
            return
        }
        buildFallback(wallpaper)
    }

    /// Reloads the scene when its properties change (debounced: color pickers fire continuously)
    private func observeProperties(of wallpaper: WEWallpaper) {
        if let propertiesObserver { NotificationCenter.default.removeObserver(propertiesObserver) }
        propertiesObserver = NotificationCenter.default.addObserver(
            forName: WallpaperProperties.didChange, object: wallpaper.wallpaperDirectory, queue: .main
        ) { [weak self] _ in self?.scheduleReload() }
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let reload = DispatchWorkItem { [weak self] in
            guard let self, let wallpaper = self.loadedWallpaper else { return }
            self.load(wallpaper)
        }
        pendingReload = reload
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: reload)
    }

    private func buildFallback(_ wallpaper: WEWallpaper) {
        let directory = wallpaper.wallpaperDirectory, file = wallpaper.project.file
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let description = try? SceneBuilder.build(directory: directory, sceneFile: file)
            DispatchQueue.main.async {
                guard let self, self.loadedDirectory == directory, let description else { return }
                self.apply(description)
            }
        }
    }

    private func apply(_ scene: SceneDescription) {
        timer?.invalidate()
        parallaxTimer?.invalidate()
        players.forEach { $0.stop() }
        players = []
        textUpdaters = []
        parallaxLayers = []
        parallaxAmount = scene.parallaxAmount
        sceneLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

        sceneSize = scene.size
        sceneLayer.bounds = CGRect(origin: .zero, size: scene.size)
        sceneLayer.backgroundColor = scene.background
        if let threeD = scene.threeD {
            sceneLayer.addSublayer(threeD.makeLayer(size: scene.size))
        }

        var layers = [Int: CALayer]()
        for node in scene.nodes {
            let layer: CALayer
            switch node.content {
            case .image(let image):
                layer = CALayer()
                layer.contents = image
            case .animation(let frames):
                layer = CALayer()
                layer.contents = frames[0].0
                let total = frames.reduce(0) { $0 + $1.1 }
                let animation = CAKeyframeAnimation(keyPath: "contents")
                animation.values = frames.map(\.0)
                var elapsed = 0.0
                animation.keyTimes = frames.map { frame in
                    defer { elapsed += frame.1 }
                    return NSNumber(value: elapsed / total)
                }
                animation.calculationMode = .discrete
                animation.duration = total
                animation.repeatCount = .infinity
                animation.isRemovedOnCompletion = false
                layer.add(animation, forKey: "sprite")
            case .text(let text):
                let textLayer = CATextLayer()
                textLayer.string = text.value
                textLayer.font = text.font
                textLayer.fontSize = CTFontGetSize(text.font)
                textLayer.foregroundColor = text.color
                textLayer.alignmentMode = text.alignment
                textLayer.contentsScale = 2
                if let script = text.script, let runner = SceneScriptRunner(script: script) {
                    textUpdaters.append((textLayer, runner, text.value))
                }
                layer = textLayer
            case .particles(let system):
                layer = system.makeLayer()
            case .none:
                layer = CALayer()
            }

            var size = node.size
            if case .text(let text) = node.content {
                // Text is laid out on a single line centered on the origin
                size = CGSize(width: max(node.size.width, 1), height: CTFontGetSize(text.font) * 1.3)
            }
            layer.bounds = CGRect(origin: .zero, size: size)
            layer.opacity = node.alpha
            if node.additive { layer.compositingFilter = CIFilter(name: "CIAdditionCompositing") }
            var transform = CATransform3DMakeRotation(node.rotation, 0, 0, 1)
            transform = CATransform3DScale(transform, node.scale.width, node.scale.height, 1)
            layer.transform = transform

            // Child origins are relative to the parent's origin (its center)
            if let parentID = node.parent, let parent = layers[parentID] {
                layer.position = CGPoint(x: parent.bounds.midX + node.origin.x, y: parent.bounds.midY + node.origin.y)
                parent.addSublayer(layer)
            } else {
                layer.position = node.origin
                sceneLayer.addSublayer(layer)
                if parallaxAmount > 0 { parallaxLayers.append((layer, node.origin, node.parallaxDepth)) }
            }
            layers[node.id] = layer

            if !node.effects.isEmpty {
                switch node.content {
                case .image(let image): SceneEffectRenderer.apply(node.effects, to: layer, image: image)
                case .animation(let frames): SceneEffectRenderer.apply(node.effects, to: layer, image: frames.first?.0)
                default: break
                }
            }
        }
        if !parallaxLayers.isEmpty {
            parallaxTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.updateParallax() }
        }

        for sound in scene.sounds {
            guard let player = try? AVAudioPlayer(data: sound.data) else { continue }
            player.numberOfLoops = -1
            player.volume = sound.volume * volume
            player.prepareToPlay()
            players.append(player)
        }

        if !textUpdaters.isEmpty {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateTexts() }
            updateTexts()
        }
        setPlaying(playing, volume: volume)
        needsLayout = true
        isLoaded = true
    }

    /// Layers drift toward the cursor proportionally to their parallax depth
    private func updateParallax() {
        guard playing, let screen = window?.screen ?? NSScreen.main else { return }
        let mouse = NSEvent.mouseLocation
        let target = CGPoint(x: (mouse.x - screen.frame.minX) / screen.frame.width,
                             y: (mouse.y - screen.frame.minY) / screen.frame.height)
        let previous = cursor
        cursor = CGPoint(x: cursor.x + (target.x - cursor.x) * 0.1, y: cursor.y + (target.y - cursor.y) * 0.1)
        guard abs(cursor.x - previous.x) + abs(cursor.y - previous.y) > 0.0005 else { return }
        let reach = sceneSize.width * 0.05 * parallaxAmount
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in parallaxLayers {
            entry.layer.position = CGPoint(x: entry.base.x + (cursor.x - 0.5) * reach * entry.depth.width,
                                           y: entry.base.y + (cursor.y - 0.5) * reach * entry.depth.height)
        }
        CATransaction.commit()
    }

    private func updateTexts() {
        guard playing else { return }
        for updater in textUpdaters {
            if let value = updater.runner.update(updater.value) { updater.layer.string = value }
        }
    }

    func setPlaying(_ playing: Bool, volume: Float) {
        // the faithful engine takes its volume at launch
        if engine != nil, volume != self.volume { scheduleReload() }
        self.playing = playing
        self.volume = volume
        engine?.setPaused(!playing)
        sceneLayer.speed = playing ? 1 : 0
        for player in players {
            player.volume = volume
            if playing && volume > 0 { if !player.isPlaying { player.play() } } else { player.pause() }
        }
    }

    override func layout() {
        super.layout()
        // Fill the screen like Wallpaper Engine: scale to cover, keep the center
        let scale = max(bounds.width / sceneSize.width, bounds.height / sceneSize.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sceneLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        sceneLayer.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    deinit {
        if let propertiesObserver { NotificationCenter.default.removeObserver(propertiesObserver) }
        engine?.stop()
        timer?.invalidate()
        parallaxTimer?.invalidate()
        players.forEach { $0.stop() }
    }
}
