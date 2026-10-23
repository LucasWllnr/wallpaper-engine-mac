//
//  SceneExtras.swift
//  Open Wallpaper Engine
//
//  Particles (mapped onto CAEmitterLayer) and effects (approximated with Core Animation
//  and Core Image, using the effect masks) for Wallpaper Engine scenes.
//

import CoreImage
import Foundation
import QuartzCore

/// Files shipped with Wallpaper Engine itself (particle presets, effect masks, materials)
enum WEAssets {
    /// Steam console command that downloads them on a Mac (Wallpaper Engine has only a Windows depot)
    static let downloadCommand = "download_depot 431960 431961"

    static var directory: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [UserDefaults.standard.string(forKey: "WallpaperEngineAssets").map { URL(filePath: $0) }].compactMap { $0 } + [
            // where `download_depot` puts the Windows depot
            home.appending(path: "Library/Application Support/Steam/steamapps/content/app_431960/depot_431961/assets"),
            home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets"),
            // Windows Steam under Wine
            home.appending(path: "Jeux/Steam/drive_c/Program Files (x86)/Steam/steamapps/common/wallpaper_engine/assets"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.appending(path: "shaders").path(percentEncoded: false)) }
    }
}

// MARK: - Particles

struct SceneParticleSystem {
    struct Emitter {
        var origin: CGPoint
        var shape: CAEmitterLayerEmitterShape
        var size: CGSize
        var birthRate: Float
        var lifetime: Float
        var lifetimeRange: Float
        var velocity: CGFloat
        var velocityRange: CGFloat
        var longitude: CGFloat
        var emissionRange: CGFloat
        var acceleration: CGVector
        var scale: CGFloat
        var scaleRange: CGFloat
        var scaleSpeed: CGFloat
        var alpha: Float
        var alphaRange: Float
        var alphaSpeed: Float
        var color: (red: Float, green: Float, blue: Float)
        var colorRange: (red: Float, green: Float, blue: Float)
        var spin: CGFloat
        var spinRange: CGFloat
        var image: CGImage
    }

    var emitters = [Emitter]()
    var additive = false
    var prewarm: Double = 0

    /// Reads a particle system json (+ the object's instance override)
    static func load(_ path: String, override: [String: Any], package: WEScenePackage,
                     texture: (String) -> WETexture?) -> SceneParticleSystem? {
        guard let json = package.json(path) else { return nil }
        var system = SceneParticleSystem()
        let n = SceneBuilder.number, v = SceneBuilder.vector
        func overrideValue(_ key: String) -> Double { n(override[key]) ?? 1 }

        // Material -> texture
        guard let materialPath = json["material"] as? String,
              let material = package.json(materialPath),
              let pass = (material["passes"] as? [[String: Any]])?.first,
              let textureName = (pass["textures"] as? [Any])?.first as? String,
              let texture = texture(textureName),
              let baseImage = texture.animation.first?.0 ?? texture.croppedImage
        else { return nil }
        system.additive = (pass["blending"] as? String) == "additive"

        let initializers = Dictionary((json["initializer"] as? [[String: Any]] ?? []).map { ($0["name"] as? String ?? "", $0) },
                                      uniquingKeysWith: { a, _ in a })
        let operators = Dictionary((json["operator"] as? [[String: Any]] ?? []).map { ($0["name"] as? String ?? "", $0) },
                                   uniquingKeysWith: { a, _ in a })
        let renderer = (json["renderer"] as? [[String: Any]])?.first

        // Lifetime
        let lifetime = initializers["lifetimerandom"]
        let lifeMin = (n(lifetime?["min"]) ?? 1) * overrideValue("lifetime")
        let lifeMax = (n(lifetime?["max"]) ?? 1) * overrideValue("lifetime")

        // Size (diameter in scene units)
        let size = initializers["sizerandom"]
        let sizeMin = (n(size?["min"]) ?? 20) * overrideValue("size")
        let sizeMax = (n(size?["max"]) ?? 20) * overrideValue("size")

        // Velocity
        let velocity = initializers["velocityrandom"]
        let speedScale = overrideValue("speed")
        let vMin = (v(velocity?["min"]) ?? [0, 0, 0]).map { $0 * speedScale }
        let vMax = (v(velocity?["max"]) ?? [0, 0, 0]).map { $0 * speedScale }
        let mean = CGVector(dx: ((vMin[safe: 0] ?? 0) + (vMax[safe: 0] ?? 0)) / 2, dy: ((vMin[safe: 1] ?? 0) + (vMax[safe: 1] ?? 0)) / 2)
        let speed = hypot(mean.dx, mean.dy)
        let speedMin = hypot(vMin[safe: 0] ?? 0, vMin[safe: 1] ?? 0), speedMax = hypot(vMax[safe: 0] ?? 0, vMax[safe: 1] ?? 0)
        let angleMin = atan2(vMin[safe: 1] ?? 0, vMin[safe: 0] ?? 0), angleMax = atan2(vMax[safe: 1] ?? 0, vMax[safe: 0] ?? 0)
        let longitude = speed > 0.01 ? atan2(mean.dy, mean.dx) : 0
        let spread = speed > 0.01 ? abs(angleMax - angleMin) / 2 : .pi

        // Gravity
        let gravity = v(operators["movement"]?["gravity"]) ?? [0, 0, 0]

        // Alpha and color
        let alphaInit = initializers["alpharandom"]
        let alphaMin = (n(alphaInit?["min"]) ?? 1) * overrideValue("alpha")
        let alphaMax = (n(alphaInit?["max"]) ?? 1) * overrideValue("alpha")
        var color: [Double] = [1, 1, 1], colorRange: [Double] = [0, 0, 0]
        if let colorInit = initializers["colorrandom"] {
            let cMin = (v(colorInit["min"]) ?? [255, 255, 255]).map { $0 / 255 }
            let cMax = (v(colorInit["max"]) ?? [255, 255, 255]).map { $0 / 255 }
            color = (0..<3).map { ((cMin[safe: $0] ?? 1) + (cMax[safe: $0] ?? 1)) / 2 }
            colorRange = (0..<3).map { abs((cMax[safe: $0] ?? 1) - (cMin[safe: $0] ?? 1)) / 2 }
        }
        if let tint = v(override["color"]), tint.count >= 3 {
            let scale = tint.contains { $0 > 1 } ? 255.0 : 1.0
            color = (0..<3).map { color[$0] * tint[$0] / scale }
        }

        // Rotation
        let angular = initializers["angularvelocityrandom"]
        let spinMin = (v(angular?["min"]) ?? [0, 0, 0]).last ?? 0, spinMax = (v(angular?["max"]) ?? [0, 0, 0]).last ?? 0

        // Fading and size change over the lifetime (Core Animation only interpolates linearly)
        let lifeMean = max((lifeMin + lifeMax) / 2, 0.01)
        var alphaSpeed = 0.0
        if let fade = operators["alphafade"], (n(fade["fadeouttime"]) ?? 1) < 1 {
            alphaSpeed = -((alphaMin + alphaMax) / 2) / lifeMean
        }
        var sizeSpeed = 0.0
        if let change = operators["sizechange"] {
            let start = n(change["startvalue"]) ?? 1, end = n(change["endvalue"]) ?? 1
            sizeSpeed = (end - start) / lifeMean
        }

        // Streaks (rain): the sprite is stretched along the mean velocity
        var image = baseImage
        if (renderer?["name"] as? String)?.hasPrefix("spritetrail") == true, speed > 1 {
            let length = min(speed * (n(renderer?["length"]) ?? 0.05) * 20, n(renderer?["maxlength"]) ?? 400)
            image = Self.streak(baseImage, length: max(length, Double(baseImage.width)), angle: longitude) ?? baseImage
        }
        let imageExtent = Double(max(baseImage.width, baseImage.height, 1))
        let meanSize = (sizeMin + sizeMax) / 2

        // Rate and count
        let rateScale = overrideValue("rate") * overrideValue("count")
        let maxCount = (n(json["maxcount"]) ?? 1000) * overrideValue("count")
        system.prewarm = max(n(json["starttime"]) ?? 0, lifeMax)

        for emitter in json["emitter"] as? [[String: Any]] ?? [] {
            let origin = v(emitter["origin"]) ?? [0, 0, 0]
            let distance = v(emitter["distancemax"]) ?? [0]
            let directions = v(emitter["directions"]) ?? [1, 1, 1]
            let dx = (distance[safe: 0] ?? 0) * (directions[safe: 0] ?? 1)
            let dy = (distance[safe: 1] ?? distance[safe: 0] ?? 0) * (directions[safe: 1] ?? 1)
            let isSphere = (emitter["name"] as? String ?? "").contains("sphere")
            var rate = (n(emitter["rate"]) ?? 10) * rateScale
            rate = min(rate, maxCount / lifeMean)
            system.emitters.append(Emitter(
                origin: CGPoint(x: origin[safe: 0] ?? 0, y: origin[safe: 1] ?? 0),
                shape: dx < 1 && dy < 1 ? .point : (isSphere ? .circle : .rectangle),
                size: CGSize(width: dx * 2, height: dy * 2),
                birthRate: Float(rate),
                lifetime: Float(lifeMean),
                lifetimeRange: Float((lifeMax - lifeMin) / 2),
                velocity: speed,
                velocityRange: abs(speedMax - speedMin) / 2,
                longitude: longitude,
                emissionRange: spread,
                acceleration: CGVector(dx: gravity[safe: 0] ?? 0, dy: gravity[safe: 1] ?? 0),
                scale: meanSize / imageExtent,
                scaleRange: abs(sizeMax - sizeMin) / 2 / imageExtent,
                scaleSpeed: sizeSpeed * meanSize / imageExtent,
                alpha: Float((alphaMin + alphaMax) / 2),
                alphaRange: Float(abs(alphaMax - alphaMin) / 2),
                alphaSpeed: Float(alphaSpeed),
                color: (Float(color[0]), Float(color[1]), Float(color[2])),
                colorRange: (Float(colorRange[0]), Float(colorRange[1]), Float(colorRange[2])),
                spin: (spinMin + spinMax) / 2,
                spinRange: abs(spinMax - spinMin) / 2,
                image: image))
        }
        return system.emitters.isEmpty ? nil : system
    }

    /// Sprite stretched to `length` along `angle` (y-up radians)
    private static func streak(_ image: CGImage, length: Double, angle: CGFloat) -> CGImage? {
        let width = Double(image.width)
        let side = Int(ceil(max(length, width)))
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        context.rotate(by: angle - .pi / 2)
        context.draw(image, in: CGRect(x: -width / 2, y: -length / 2, width: width, height: length))
        return context.makeImage()
    }

    func makeLayer() -> CAEmitterLayer {
        let layer = CAEmitterLayer()
        layer.renderMode = additive ? .additive : .unordered
        layer.emitterMode = .volume
        layer.emitterCells = emitters.map { emitter in
            let cell = CAEmitterCell()
            cell.contents = emitter.image
            cell.birthRate = emitter.birthRate
            cell.lifetime = emitter.lifetime
            cell.lifetimeRange = emitter.lifetimeRange
            cell.velocity = emitter.velocity
            cell.velocityRange = emitter.velocityRange
            cell.emissionLongitude = emitter.longitude
            cell.emissionRange = emitter.emissionRange
            cell.xAcceleration = emitter.acceleration.dx
            cell.yAcceleration = emitter.acceleration.dy
            cell.scale = emitter.scale
            cell.scaleRange = emitter.scaleRange
            cell.scaleSpeed = emitter.scaleSpeed
            cell.alphaRange = emitter.alphaRange
            cell.alphaSpeed = emitter.alphaSpeed
            cell.color = CGColor(red: CGFloat(emitter.color.red), green: CGFloat(emitter.color.green),
                                 blue: CGFloat(emitter.color.blue), alpha: CGFloat(emitter.alpha))
            cell.redRange = emitter.colorRange.red
            cell.greenRange = emitter.colorRange.green
            cell.blueRange = emitter.colorRange.blue
            cell.spin = emitter.spin
            cell.spinRange = emitter.spinRange
            return cell
        }
        // One emitter layer per system: cells share the first emitter's shape and origin
        if let first = emitters.first {
            layer.emitterShape = first.shape
            layer.emitterSize = first.size
            layer.emitterPosition = first.origin
        }
        layer.beginTime = CACurrentMediaTime() - prewarm
        return layer
    }
}

// MARK: - Effects

struct SceneEffect {
    var kind: String
    var values: [String: Any]
    /// Alpha mask in the layer's image space (white = affected)
    var mask: CGImage?

    func number(_ key: String, _ fallback: Double) -> Double { SceneBuilder.number(values[key]) ?? fallback }
    func vector(_ key: String, _ fallback: [Double]) -> [Double] { SceneBuilder.vector(values[key]) ?? fallback }

    /// effects/<kind>/effect.json + first pass values and mask
    static func load(_ effect: [String: Any], package: WEScenePackage, texture: (String) -> WETexture?) -> SceneEffect? {
        guard SceneBuilder.bool(effect["visible"]) ?? true,
              let file = effect["file"] as? String
        else { return nil }
        let kind = URL(filePath: file).deletingLastPathComponent().lastPathComponent
        let pass = (effect["passes"] as? [[String: Any]])?.first ?? [:]
        let values = pass["constantshadervalues"] as? [String: Any] ?? [:]
        var mask: CGImage?
        if let textures = pass["textures"] as? [Any], textures.count > 1, let name = textures[1] as? String,
           let image = texture(name)?.croppedImage {
            mask = alphaMask(from: image)
        }
        return SceneEffect(kind: kind, values: values, mask: mask)
    }

    /// Grayscale texture -> image whose alpha is the gray level
    static func alphaMask(from image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let gray = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        gray.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = gray.data,
              let provider = CGDataProvider(data: Data(bytes: data, count: width * height) as CFData)
        else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.alphaOnly.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

enum SceneEffectRenderer {
    /// Applies the effects of one image layer; masked effects animate a masked copy on top
    static func apply(_ effects: [SceneEffect], to layer: CALayer, image: CGImage?) {
        let size = layer.bounds.size
        let extent = max(min(size.width, size.height), 1)
        // Light effects only light their masked spots in Wallpaper Engine; unmasked ones would
        // brighten the whole picture, and stacked ones (a scene can have 15) would burn it white
        let lights = effects.filter { ["godrays", "lightshafts", "shine"].contains($0.kind) && $0.mask != nil }
        let lightShare = 1 / Double(max(lights.count, 1))
        var lightsApplied = 0
        for effect in effects {
            if ["godrays", "lightshafts", "shine", "pulse"].contains(effect.kind) && effect.mask == nil { continue }
            if ["godrays", "lightshafts", "shine"].contains(effect.kind) {
                lightsApplied += 1
                if lightsApplied > 3 { continue }
            }
            switch effect.kind {
            case "shake":
                let amplitude = effect.number("strength", 0.1) * 0.1 * extent
                let period = 1 / max(effect.number("speed", 1), 0.05)
                animate(effect, layer, image) { target in
                    target.add(wobble("position", amplitude: amplitude, period: period, randomized: true), forKey: "shake")
                }
            case "waterwaves", "waterripple", "cloudmotion":
                let strength = effect.kind == "waterripple" ? effect.number("ripplestrength", 0.1) : effect.number("strength", 0.1)
                let amplitude = strength * 0.03 * extent
                let period = 6 / max(effect.number("speed", 5) * (effect.kind == "cloudmotion" ? 0.2 : 1), 0.1)
                animate(effect, layer, image) { target in
                    target.add(wobble("position", amplitude: amplitude, period: period, randomized: false), forKey: effect.kind)
                }
            case "waterflow":
                let amplitude = effect.number("strength", 1) * 0.01 * extent
                let period = 4 / max(effect.number("speed", 1), 0.05)
                animate(effect, layer, image) { target in
                    target.add(wobble("position", amplitude: amplitude, period: period, randomized: false), forKey: "waterflow")
                }
            case "foliagesway", "swing":
                let angle = effect.kind == "swing" ? effect.number("amount", 0.2) * 0.3 : effect.number("strength", 0.4) * 0.04
                let period = (effect.kind == "swing" ? 3 : 4) / max(effect.number("speed", 1), 0.05)
                animate(effect, layer, image, anchorBottom: true) { target in
                    target.add(sway(angle: angle, period: period), forKey: effect.kind)
                }
            case "spin":
                let speed = effect.number("speed", 1)
                animate(effect, layer, image) { target in
                    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                    spin.byValue = speed >= 0 ? -2 * Double.pi : 2 * Double.pi
                    spin.duration = 2 * .pi / max(abs(speed), 0.05)
                    spin.repeatCount = .infinity
                    spin.isAdditive = true
                    target.add(spin, forKey: "spin")
                }
            case "pulse":
                let amount = min(effect.number("amount", 1), 1)
                let period = 2 * .pi / max(effect.number("speed", 3), 0.05)
                let overlay = maskedCopy(of: layer, image: image, mask: effect.mask)
                overlay.compositingFilter = CIFilter(name: "CIAdditionCompositing")
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 0
                pulse.toValue = amount * 0.25
                pulse.duration = period / 2
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                overlay.add(pulse, forKey: "pulse")
                layer.addSublayer(overlay)
            case "tint":
                let color = effect.vector("color", [1, 0, 0])
                guard let image, let tinted = tint(image, color) else { break }
                let overlay = maskedCopy(of: layer, image: tinted, mask: effect.mask)
                overlay.opacity = Float(effect.number("alpha", 1))
                layer.addSublayer(overlay)
            case "opacity":
                let alpha = effect.number("alpha", 1)
                if let mask = effect.mask {
                    // Keep unmasked pixels, fade masked ones to `alpha`
                    let maskLayer = CALayer()
                    maskLayer.frame = layer.bounds
                    maskLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
                    let cut = CALayer()
                    cut.frame = layer.bounds
                    cut.contents = mask
                    cut.compositingFilter = CIFilter(name: "CISourceOutCompositing")
                    maskLayer.addSublayer(cut)
                    let keep = CALayer()
                    keep.frame = layer.bounds
                    keep.contents = mask
                    keep.opacity = Float(alpha)
                    maskLayer.addSublayer(keep)
                    layer.mask = maskLayer
                } else {
                    layer.opacity *= Float(alpha)
                }
            case "blur", "blurprecise", "blurradial", "motionblur":
                // Blur baked into the contents: a live CIFilter on the layer can render the
                // transparent parts black on macOS and costs GPU time every frame
                let radius = (effect.vector("scale", [1, 1]).first ?? 1) * 4
                if let animation = layer.animation(forKey: "sprite") as? CAKeyframeAnimation,
                   let frames = animation.values as? [CGImage] {
                    let blurredFrames = frames.map { blurred($0, radius: radius) ?? $0 }
                    let copy = animation.copy() as! CAKeyframeAnimation
                    copy.values = blurredFrames
                    layer.add(copy, forKey: "sprite")
                    layer.contents = blurredFrames.first
                } else if let current = (layer.contents as! CGImage?) ?? image, let soft = blurred(current, radius: radius) {
                    layer.contents = soft
                }
            case "scroll":
                guard let image, let tiled = tile(image) else { break }
                layer.contents = tiled
                layer.contentsRect = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
                let speedX = effect.number("speedx", 0.2), speedY = effect.number("speedy", 0.2)
                let duration = 1 / max(abs(speedX), abs(speedY), 0.01)
                let scroll = CABasicAnimation(keyPath: "contentsRect")
                scroll.fromValue = CGRect(x: speedX < 0 ? 0.5 : 0, y: speedY < 0 ? 0 : 0.5, width: 0.5, height: 0.5)
                scroll.toValue = CGRect(x: speedX < 0 ? 0 : (speedX == 0 ? 0 : 0.5), y: speedY < 0 ? 0.5 : (speedY == 0 ? 0.5 : 0), width: 0.5, height: 0.5)
                scroll.duration = duration
                scroll.repeatCount = .infinity
                layer.add(scroll, forKey: "scroll")
            case "godrays", "lightshafts", "shine":
                // Light that comes from the bright parts of the image itself: an additive, blurred
                // copy of the image (bloom) follows its shape, so no rectangular halo appears
                guard let image, let glow = blurred(image, radius: Double(max(image.width, image.height)) * 0.02) else { break }
                let rays = maskedCopy(of: layer, image: glow, mask: effect.mask)
                rays.compositingFilter = CIFilter(name: "CIAdditionCompositing")
                let threshold = effect.number("raythreshold", 0.5)
                // Several light effects often stack on one layer: keep each one subtle
                rays.opacity = Float(min(effect.number("rayintensity", 1), 1) * (1 - threshold) * 0.4 * lightShare)
                let flicker = CABasicAnimation(keyPath: "opacity")
                flicker.fromValue = rays.opacity * 0.5
                flicker.toValue = rays.opacity
                flicker.duration = 2 / max(effect.number("noisespeed", 0.15) * 4, 0.1)
                flicker.autoreverses = true
                flicker.repeatCount = .infinity
                flicker.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                rays.add(flicker, forKey: "rays")
                layer.addSublayer(rays)
            case "clouds":
                // Colored clouds over the masked area: gradient between the two colors, drifting slowly
                let start = effect.vector("colorstart", [1, 1, 1]), end = effect.vector("colorend", start)
                let clouds = CAGradientLayer()
                clouds.frame = layer.bounds
                clouds.colors = [start, end].map { CGColor(red: $0[safe: 0] ?? 1, green: $0[safe: 1] ?? 1, blue: $0[safe: 2] ?? 1, alpha: 1) }
                clouds.startPoint = CGPoint(x: 0, y: 1)
                clouds.endPoint = CGPoint(x: 1, y: 0)
                clouds.opacity = Float(min(effect.number("alpha", 1), 1) * 0.7)
                let maskLayer = CALayer()
                maskLayer.frame = layer.bounds
                maskLayer.contents = effect.mask ?? image
                clouds.mask = maskLayer
                let drift = CABasicAnimation(keyPath: "startPoint")
                drift.fromValue = CGPoint(x: 0, y: 1)
                drift.toValue = CGPoint(x: 0.4, y: 0.6)
                drift.duration = 12
                drift.autoreverses = true
                drift.repeatCount = .infinity
                clouds.add(drift, forKey: "clouds")
                layer.addSublayer(clouds)
            case "shimmer":
                let band = CAGradientLayer()
                band.frame = layer.bounds
                band.startPoint = CGPoint(x: 0, y: 0.5)
                band.endPoint = CGPoint(x: 1, y: 0.5)
                band.colors = [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.5), CGColor(gray: 1, alpha: 0)]
                band.locations = [-0.3, -0.15, 0]
                band.compositingFilter = CIFilter(name: "CIAdditionCompositing")
                let maskLayer = CALayer()
                maskLayer.frame = layer.bounds
                maskLayer.contents = effect.mask ?? image
                band.mask = maskLayer
                let sweep = CABasicAnimation(keyPath: "locations")
                sweep.fromValue = [-0.3, -0.15, 0]
                sweep.toValue = [1, 1.15, 1.3]
                sweep.duration = 3
                let group = CAAnimationGroup()
                group.animations = [sweep]
                group.duration = 3 + 2 / max(effect.number("speed", 1), 0.1)
                group.repeatCount = .infinity
                band.add(group, forKey: "shine")
                layer.addSublayer(band)
            case "skew":
                var transform = CATransform3DIdentity
                transform.m21 = CGFloat(effect.number("top", 0) - effect.number("bottom", 0)) * 0.5
                transform.m12 = CGFloat(effect.number("left", 0) - effect.number("right", 0)) * 0.5
                layer.sublayerTransform = transform
            default:
                break // Shader effects without a Core Animation equivalent are skipped
            }
        }
    }

    // MARK: Helpers

    /// Animates the whole layer, or a masked copy of it when the effect has a mask
    private static func animate(_ effect: SceneEffect, _ layer: CALayer, _ image: CGImage?, anchorBottom: Bool = false,
                                _ add: (CALayer) -> Void) {
        if effect.mask != nil {
            let copy = maskedCopy(of: layer, image: image, mask: effect.mask)
            if anchorBottom {
                copy.anchorPoint = CGPoint(x: 0.5, y: 0)
                copy.position = CGPoint(x: layer.bounds.midX, y: 0)
            }
            layer.addSublayer(copy)
            add(copy)
        } else {
            add(layer)
        }
    }

    private static func maskedCopy(of layer: CALayer, image: CGImage?, mask: CGImage?) -> CALayer {
        let copy = CALayer()
        copy.frame = layer.bounds
        copy.contents = image
        if let mask {
            let maskLayer = CALayer()
            maskLayer.frame = layer.bounds
            maskLayer.contents = mask
            copy.mask = maskLayer
        }
        return copy
    }

    /// Smooth periodic offset (additive, composes with the layer's own position)
    private static func wobble(_ keyPath: String, amplitude: Double, period: Double, randomized: Bool) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        let steps = 24
        animation.values = (0...steps).map { step -> NSValue in
            let t = Double(step) / Double(steps) * 2 * .pi
            let x = randomized ? sin(t * 3) * cos(t * 2) : sin(t) * 0.3
            let y = randomized ? cos(t * 5) * sin(t) : sin(t)
            return NSValue(point: CGPoint(x: x * amplitude, y: y * amplitude))
        }
        animation.duration = period * (randomized ? 4 : 1)
        animation.repeatCount = .infinity
        animation.isAdditive = true
        animation.calculationMode = .cubic
        return animation
    }

    private static func sway(angle: Double, period: Double) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = [-angle, angle, -angle]
        animation.duration = period
        animation.repeatCount = .infinity
        animation.isAdditive = true
        animation.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        return animation
    }

    private static func tint(_ image: CGImage, _ color: [Double]) -> CGImage? {
        guard color.count >= 3, let filter = CIFilter(name: "CIColorMatrix") else { return nil }
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: color[0], y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: color[1], z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: color[2], w: 0), forKey: "inputBVector")
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }

    /// Gaussian blur keeping the image size (edges clamped, so no dark border)
    private static func blurred(_ image: CGImage, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let output = input.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(radius, 1)])
                .cropped(to: input.extent) as CIImage?
        else { return nil }
        return CIContext().createCGImage(output, from: input.extent)
    }

    /// 2x2 tiling so contentsRect can scroll seamlessly
    private static func tile(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width * 2, height: height * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        for x in 0..<2 { for y in 0..<2 {
            context.draw(image, in: CGRect(x: x * width, y: y * height, width: width, height: height))
        } }
        return context.makeImage()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
