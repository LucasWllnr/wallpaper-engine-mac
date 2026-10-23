//
//  FaithfulSceneEngine.swift
//  Open Wallpaper Engine
//
//  Runs scenes with the real Wallpaper Engine shaders through linux-wallpaperengine built for macOS
//  (tools/build-lwe.sh + tools/lwe-macos.patch), as a desktop-level window. Scenes it cannot render
//  (3D models, unsupported content, crashes) end the process: the caller then falls back to the
//  built-in Core Animation renderer, so every scene still shows something equivalent.
//

import AppKit

final class FaithfulSceneEngine {
    /// Called on the main thread when the engine stops by itself (unsupported scene or crash)
    var onFailure: (() -> Void)?

    private var process: Process?
    private var stopping = false
    /// Engines currently on the desktop, stopped when the app quits
    private static var running = Set<pid_t>()

    static func stopAll() {
        running.forEach { kill($0, SIGKILL) }
        running.removeAll()
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "UseFaithfulRenderer") as? Bool ?? true
    }

    /// Bundled next to the app's executable (tools/package-owe.sh), else a development build
    static var binary: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let relative = "engine/linux-wallpaperengine/build/output/linux-wallpaperengine"
        let candidates = [UserDefaults.standard.string(forKey: "FaithfulEngineBinary"),
                          Bundle.main.url(forAuxiliaryExecutable: "linux-wallpaperengine")?.path].compactMap { $0 }
            + ["Desktop/ia/wallpaperEngineMac", "Desktop/ia/steam on mac", "steam on mac"].map { home.appendingPathComponent($0).appendingPathComponent(relative).path }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    static var assets: URL? { WEAssets.directory }

    /// Starts rendering the scene in `directory` over `screen`; false when the engine is unavailable
    func start(directory: URL, screen: NSScreen?, volume: Float) -> Bool {
        guard Self.isEnabled, let binary = Self.binary, let assets = Self.assets,
              let screen = screen ?? NSScreen.main else { return false }
        // GLFW positions windows from the top-left of the primary screen
        let frame = screen.frame
        let top = (NSScreen.screens.first?.frame.maxY ?? frame.maxY) - frame.maxY
        var arguments = ["--assets-dir", assets.path,
                         "--window", "\(Int(frame.minX))x\(Int(top))x\(Int(frame.width))x\(Int(frame.height))",
                         "--scaling", "fill", "--noautomute", "--no-audio-processing",
                         // the FPS of the Performance settings: each frame costs GPU time the rest of the Mac needs
                         "--fps", String(Int(AppDelegate.shared.globalSettingsViewModel.settings.fps))]
        arguments += volume > 0 ? ["--volume", String(Int(volume * 128))] : ["--silent"]
        arguments += WallpaperProperties.engineArguments(for: directory)
        arguments.append(directory.path)

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var environment = ["LWE_DESKTOP": "1"]
        // "High Performance" textures: draw the final image at 1x instead of the Retina resolution (4x fewer pixels)
        if AppDelegate.shared.globalSettingsViewModel.settings.textureResolution == .highPerformance { environment["LWE_NO_RETINA"] = "1" }
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.process === ended, !self.stopping else { return }
                self.process = nil
                self.onFailure?()
            }
        }
        do { try process.run() } catch { return false }
        self.process = process
        Self.running.insert(process.processIdentifier)
        return true
    }

    /// Renders one still frame of the scene off screen (used as the macOS desktop picture behind the menu bar)
    static func snapshot(directory: URL, to output: URL, completion: @escaping (Bool) -> Void) {
        guard isEnabled, let binary, let assets else { return completion(false) }
        try? FileManager.default.removeItem(at: output)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--assets-dir", assets.path, "--window", "0x0x1920x1080", "--scaling", "fill",
                             "--silent", "--noautomute", "--no-audio-processing",
                             "--screenshot-delay", "120", "--screenshot", output.path]
            + WallpaperProperties.engineArguments(for: directory) + [directory.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["LWE_HIDDEN_WINDOW": "1"]) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return completion(false) }

        DispatchQueue.global(qos: .utility).async {
            // the PNG is written by a background thread of the engine: wait until its size settles
            var last = -1, size = 0
            for _ in 0..<100 where process.isRunning {
                usleep(200_000)
                size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 0 && size == last { break }
                last = size
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            DispatchQueue.main.async { completion(size > 0) }
        }
    }

    func setPaused(_ paused: Bool) {
        guard let process, process.isRunning else { return }
        kill(process.processIdentifier, paused ? SIGSTOP : SIGCONT)
    }

    func stop() {
        stopping = true
        guard let process, process.isRunning else { return }
        // the engine can crash while tearing down on SIGTERM, a hard stop is cleaner
        kill(process.processIdentifier, SIGKILL)
        Self.running.remove(process.processIdentifier)
        self.process = nil
    }

    deinit { stop() }
}
