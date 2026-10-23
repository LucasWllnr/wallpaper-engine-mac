//
//  SceneThreeD.swift
//  Open Wallpaper Engine
//
//  3D part of Wallpaper Engine scenes: .mdl meshes (static and skinned, shown in their
//  rest pose), object hierarchy, lights and perspective camera, rendered with SceneKit.
//

import Foundation
import SceneKit

struct SceneThreeD {
    struct Mesh {
        var positions: [SCNVector3]
        var normals: [SCNVector3]
        var uvs: [CGPoint]
        var indices: [UInt16]
        var texture: CGImage?
        var color: [Double]
        var additive: Bool
    }

    struct Object {
        var id: Int
        var parent: Int?
        var origin: [Double]
        var angles: [Double]
        var scale: [Double]
        var meshes = [Mesh]()
        var light: (kind: String, color: [Double], intensity: Double, radius: Double)?
    }

    var eye: [Double] = [0, 0, 10]
    var center: [Double] = [0, 0, 0]
    var up: [Double] = [0, 1, 0]
    var fov: Double = 50
    var near: Double = 0.1
    var far: Double = 10000
    var ambient: [Double] = [0.3, 0.3, 0.3]
    var objects = [Object]()
    /// Scene camera object (origin + Euler angles), preferred over the scene's default camera
    var cameraObject: (origin: [Double], angles: [Double])?

    var hasContent: Bool { objects.contains { !$0.meshes.isEmpty } }

    // MARK: .mdl

    /// Reads every mesh it can understand (vertex formats 15 = static, 0x0180000F = skinned)
    static func readModel(_ data: Data, package: WEScenePackage, texture: (String) -> WETexture?) -> [Mesh] {
        var r = BinaryReader(data: Data(data))
        guard let tag = try? r.tag(), tag.hasPrefix("MDLV"),
              (try? r.u32()) != nil, (try? r.u32()) != nil, let meshCount = try? r.u32()
        else { return [] }
        var meshes = [Mesh]()
        for _ in 0..<min(meshCount, 64) {
            guard let materialPath = readCString(&r),
                  (try? r.u32()) != nil
            else { break }
            for _ in 0..<6 { _ = try? r.f32() } // bounding box
            guard let format = try? r.u32(), let vertexBytes = try? r.u32() else { break }
            let stride: Int, uvOffset: Int
            switch format {
            case 15: stride = 48; uvOffset = 40
            case 0x0180000F: stride = 80; uvOffset = 72
            default: return meshes
            }
            guard vertexBytes % stride == 0, let vertices = try? r.bytes(vertexBytes),
                  let indexBytes = try? r.u32(), let indexData = try? r.bytes(indexBytes)
            else { break }

            let count = vertexBytes / stride
            var positions = [SCNVector3](), normals = [SCNVector3](), uvs = [CGPoint]()
            positions.reserveCapacity(count); normals.reserveCapacity(count); uvs.reserveCapacity(count)
            vertices.withUnsafeBytes { raw in
                func f(_ offset: Int) -> CGFloat { CGFloat(raw.loadUnaligned(fromByteOffset: offset, as: Float.self)) }
                for i in 0..<count {
                    let base = i * stride
                    positions.append(SCNVector3(f(base), f(base + 4), f(base + 8)))
                    normals.append(SCNVector3(f(base + 12), f(base + 16), f(base + 20)))
                    uvs.append(CGPoint(x: f(base + uvOffset), y: f(base + uvOffset + 4)))
                }
            }
            let indices = indexData.withUnsafeBytes { raw in
                (0..<(indexBytes / 2)).map { raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self) }
            }

            // Material: first texture and constant color
            var image: CGImage?, color: [Double] = [1, 1, 1], additive = false
            if let material = package.json(materialPath), let pass = (material["passes"] as? [[String: Any]])?.first {
                if let name = (pass["textures"] as? [Any])?.first as? String { image = texture(name)?.croppedImage }
                color = SceneBuilder.vector((pass["constantshadervalues"] as? [String: Any])?["color"]) ?? color
                additive = (pass["blending"] as? String) == "additive"
            }
            meshes.append(Mesh(positions: positions, normals: normals, uvs: uvs, indices: indices,
                               texture: image, color: color, additive: additive))
        }
        return meshes
    }

    private static func readCString(_ r: inout BinaryReader) -> String? {
        // Skinned meshes are separated by a few zero bytes; material paths never start with one
        var skipped = 0
        while skipped < 16, r.remaining > 0, r.data[r.data.startIndex + r.offset] == 0 { r.offset += 1; skipped += 1 }
        var bytes = [UInt8]()
        while r.remaining > 0, let byte = try? r.bytes(1).first {
            if byte == 0 { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
            if bytes.count > 512 { return nil }
        }
        return nil
    }

    // MARK: SceneKit

    func makeLayer(size: CGSize) -> SCNLayer {
        let scene = SCNScene()
        // Wallpaper Engine is left-handed (Direct3D style); SceneKit is right-handed: mirror Z
        let world = SCNNode()
        world.scale = SCNVector3(1, 1, -1)
        scene.rootNode.addChildNode(world)
        var nodes = [Int: SCNNode]()
        for object in objects {
            let node = SCNNode()
            node.position = vector(object.origin, 0)
            node.eulerAngles = vector(object.angles, 0)
            node.scale = vector(object.scale, 1)
            for mesh in object.meshes {
                node.addChildNode(SCNNode(geometry: geometry(mesh)))
            }
            if let light = object.light {
                let scnLight = SCNLight()
                switch light.kind {
                case "ldirectional": scnLight.type = .directional
                case "lspot": scnLight.type = .spot; scnLight.attenuationEndDistance = light.radius * 10
                default: scnLight.type = .omni; scnLight.attenuationEndDistance = light.radius * 10
                }
                scnLight.color = NSColor(red: light.color[safe: 0] ?? 1, green: light.color[safe: 1] ?? 1, blue: light.color[safe: 2] ?? 1, alpha: 1)
                scnLight.intensity = light.intensity * 400
                node.light = scnLight
            }
            nodes[object.id] = node
        }
        for object in objects {
            guard let node = nodes[object.id] else { continue }
            (object.parent.flatMap { nodes[$0] } ?? world).addChildNode(node)
        }

        let ambientNode = SCNNode()
        ambientNode.light = SCNLight()
        ambientNode.light?.type = .ambient
        ambientNode.light?.color = NSColor(red: ambient[safe: 0] ?? 0.3, green: ambient[safe: 1] ?? 0.3, blue: ambient[safe: 2] ?? 0.3, alpha: 1)
        scene.rootNode.addChildNode(ambientNode)

        let camera = SCNCamera()
        camera.fieldOfView = fov
        camera.zNear = near
        camera.zFar = far
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let mirror = { (v: [Double]) in [v[safe: 0] ?? 0, v[safe: 1] ?? 0, -(v[safe: 2] ?? 0)] }
        var eye = self.eye, center = self.center
        if let camera = cameraObject {
            // Yaw around Y, pitch around X (negative looks down), camera forward is -Z
            // (checked against the preview of a 3D workshop scene)
            let pitch = camera.angles[safe: 0] ?? 0, yaw = camera.angles[safe: 1] ?? 0
            eye = camera.origin
            center = [eye[0] - sin(yaw) * cos(pitch), eye[1] + sin(pitch), eye[2] - cos(yaw) * cos(pitch)]
        }
        cameraNode.position = vector(mirror(eye), 0)
        cameraNode.look(at: vector(mirror(center), 0), up: vector(mirror(up), 0), localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(cameraNode)

        let layer = SCNLayer()
        layer.scene = scene
        layer.pointOfView = cameraNode
        layer.isPlaying = true
        layer.backgroundColor = .clear
        layer.frame = CGRect(origin: .zero, size: size)
        return layer
    }

    private func geometry(_ mesh: Mesh) -> SCNGeometry {
        let sources = [SCNGeometrySource(vertices: mesh.positions),
                       SCNGeometrySource(normals: mesh.normals),
                       SCNGeometrySource(textureCoordinates: mesh.uvs)]
        let element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = mesh.texture ?? NSColor(red: mesh.color[safe: 0] ?? 1, green: mesh.color[safe: 1] ?? 1,
                                                            blue: mesh.color[safe: 2] ?? 1, alpha: 1)
        if mesh.texture != nil {
            material.multiply.contents = NSColor(red: mesh.color[safe: 0] ?? 1, green: mesh.color[safe: 1] ?? 1,
                                                 blue: mesh.color[safe: 2] ?? 1, alpha: 1)
        }
        material.isDoubleSided = true
        if mesh.additive { material.blendMode = .add }
        geometry.materials = [material]
        return geometry
    }

    private func vector(_ values: [Double], _ fallback: CGFloat) -> SCNVector3 {
        SCNVector3(values[safe: 0].map { CGFloat($0) } ?? fallback,
                   values[safe: 1].map { CGFloat($0) } ?? fallback,
                   values[safe: 2].map { CGFloat($0) } ?? fallback)
    }
}
