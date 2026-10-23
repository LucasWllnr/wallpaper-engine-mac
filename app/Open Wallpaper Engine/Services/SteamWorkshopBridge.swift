//
//  SteamWorkshopBridge.swift
//  Open Wallpaper Engine
//
//  Subscribing without a Web API key: the bundled `wehelper-mac` tool loads the native
//  libsteam_api.dylib as Wallpaper Engine (appid 431960) and calls ISteamUGC through the
//  Steam for Mac client, which downloads into its own workshop folder.
//

import Foundation

struct WorkshopItemState: Decodable {
    var id: String
    var state: UInt32
    var downloaded: UInt64
    var total: UInt64
    var folder: String

    var isSubscribed: Bool { state & 1 != 0 }
    var isInstalled: Bool { state & 4 != 0 && state & (8 | 16 | 32) == 0 }
    var isDownloading: Bool { state & (16 | 32) != 0 }
    var progress: Double { total > 0 ? Double(downloaded) / Double(total) : 0 }
}

enum SteamBridgeError: LocalizedError {
    case helperNotFound
    case notAllowed
    case steam(String)

    var errorDescription: String? {
        switch self {
        case .helperNotFound: "wehelper-mac is missing from the application bundle."
        case .notAllowed: "Steam access is turned off. Turn on « Use Steam » in Settings > General."
        case .steam(let message): message
        }
    }
}

final class SteamWorkshopBridge {
    static let shared = SteamWorkshopBridge()

    /// Answer of the first launch: may the app talk to Steam (Workshop pages, subscriptions, starting Steam)
    static var isAllowed: Bool {
        get { UserDefaults.standard.object(forKey: "AllowSteam") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "AllowSteam") }
    }

    /// Bundled next to libsteam_api.dylib (it loads @executable_path/libsteam_api.dylib)
    var helperURL: URL? {
        Bundle.main.url(forResource: "wehelper-mac", withExtension: nil)
    }

    var isSteamRunning: Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pgrep")
        process.arguments = ["-x", "steam_osx"]
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Runs a program and streams its stdout lines
    private func run(_ executable: URL, _ arguments: [String]) throws -> AsyncThrowingStream<String, Error> {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        return AsyncThrowingStream { continuation in
            Task.detached {
                do {
                    try process.run()
                    for try await line in pipe.fileHandleForReading.bytes.lines {
                        continuation.yield(line)
                    }
                    process.waitUntilExit()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in if process.isRunning { process.terminate() } }
        }
    }

    /// Streams wehelper.exe JSON lines as item states
    private func helper(_ arguments: [String]) throws -> AsyncThrowingStream<WorkshopItemState, Error> {
        guard Self.isAllowed else { throw SteamBridgeError.notAllowed }
        guard let helper = helperURL else { throw SteamBridgeError.helperNotFound }
        let lines = try run(helper, arguments)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await line in lines {
                        let data = Data(line.utf8)
                        if let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String {
                            throw SteamBridgeError.steam(error)
                        }
                        if let state = try? JSONDecoder().decode(WorkshopItemState.self, from: data) {
                            continuation.yield(state)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Starts Steam for Mac (in the background, without its window) if needed and waits until it answers
    func ensureSteam() async throws {
        guard Self.isAllowed else { throw SteamBridgeError.notAllowed }
        if isSteamRunning { return }
        for try await _ in try run(URL(filePath: "/usr/bin/open"), ["-g", "-a", "Steam", "--args", "-silent"]) {}
        for _ in 0..<90 {
            try await Task.sleep(for: .seconds(2))
            if isSteamRunning, (try? await status(of: []).isEmpty) != nil { return }
        }
        throw SteamBridgeError.steam("Steam did not start in time.")
    }

    func subscribedItems() async throws -> [WorkshopItemState] {
        try await ensureSteam()
        var items = [WorkshopItemState]()
        for try await item in try helper(["list"]) { items.append(item) }
        return items
    }

    func status(of ids: [String]) async throws -> [WorkshopItemState] {
        var items = [WorkshopItemState]()
        for try await item in try helper(["status"] + ids) { items.append(item) }
        return items
    }

    /// Subscribes and reports download progress until the item is installed
    func subscribe(_ id: String) async throws -> AsyncThrowingStream<WorkshopItemState, Error> {
        try await ensureSteam()
        return try helper(["subscribe", id])
    }

    func unsubscribe(_ id: String) async throws {
        try await ensureSteam()
        for try await _ in try helper(["unsubscribe", id]) {}
    }
}

/// Subscription state shared by the Workshop tab
@MainActor
final class WorkshopSubscriptions: ObservableObject {
    static let shared = WorkshopSubscriptions()

    @Published private(set) var states = [String: WorkshopItemState]()
    @Published private(set) var busy = Set<String>()
    @Published var errorMessage: String?

    /// Called after a download completes so the Installed tab can refresh
    var onInstalled: ((String) -> Void)?

    func isSubscribed(_ id: String) -> Bool { states[id]?.isSubscribed ?? false }

    /// Steam for Mac cannot enumerate subscriptions of an app it has not installed,
    /// so the state of the items on screen is asked for instead
    func refresh(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        Task {
            do {
                try await SteamWorkshopBridge.shared.ensureSteam()
                for item in try await SteamWorkshopBridge.shared.status(of: ids) {
                    states[item.id] = item
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func subscribe(_ id: String) {
        guard !busy.contains(id) else { return }
        busy.insert(id)
        Task {
            defer { busy.remove(id) }
            do {
                for try await state in try await SteamWorkshopBridge.shared.subscribe(id) {
                    states[id] = state
                }
                if states[id]?.isInstalled == true { onInstalled?(id) }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func unsubscribe(_ id: String) {
        guard !busy.contains(id) else { return }
        busy.insert(id)
        Task {
            defer { busy.remove(id) }
            do {
                try await SteamWorkshopBridge.shared.unsubscribe(id)
                states[id] = nil
                onInstalled?(id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
