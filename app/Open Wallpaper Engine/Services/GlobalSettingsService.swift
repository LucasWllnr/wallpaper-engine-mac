//
//  GlobalSettingsService.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/9/2.
//

import Cocoa
import Combine
import SwiftUI
import ServiceManagement
import IOKit.ps

enum GSQuality {
    case low, medium, high, ultra
}

enum GSPlayback: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case keepRunning, mute, pause, stop
}

enum GSAntiAliasingQuality: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case none, msaa_x2, msaa_x4, msaa_x8
}

enum GSPostProcessingQuality: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case disabled, enabled, ultra
}

enum GSTextureResolutionQuality: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case highQuality, highPerformance, automatic
}

enum GSAppearance: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case light, dark, followSystem
}

enum GSLocalization: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case en_US, zh_CN, followSystem
}

enum GSVideoFramework: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case avkit
}

enum GSProcessPiority: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case normal, belowNormal
}

enum GSLogLevel: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case error, verbose, none
}

struct GlobalSettings: Codable, Equatable {
    
    // MARK: Playback
    var otherApplicationFocused = GSPlayback.keepRunning
    // nothing of the wallpaper is visible then: rendering it only slows the Mac down
    var otherApplicationFullscreen = GSPlayback.pause
    var otherApplicationPlayingAudio = GSPlayback.keepRunning
    var displayAsleep = GSPlayback.pause
    var laptopOnBattery = GSPlayback.keepRunning
    
    // MARK: Quality
    var antiAliasing = GSAntiAliasingQuality.msaa_x2
    var postProcessing = GSPostProcessingQuality.disabled
    var textureResolution = GSTextureResolutionQuality.automatic
    var reflections = false
    var fps: Double = 30
    
    // MARK: Automatic Setup
    var autoStart = true // a wallpaper app is expected to be there after login
    var safeMode = false
    
    // MARK: Basic Setup
    var language = GSLocalization.followSystem
    
    // MARK: macOS
    var adjustMenuBarTint = true
    
    // MARK: Appearance
    var appearance = GSAppearance.followSystem
    
    // MARK: Audio
    var audioOutput = true
    var reloadWhenChangingOutputDevice = true // Not putting in use
    
    // MARK: Video
    var videoFramework = GSVideoFramework.avkit
    
    // MARK: Advanced
    var processPiority = GSProcessPiority.normal // Not putting in use
    var pauseOnVRAMExhausted = false // Not putting in use
    var restartAfterCrashing = false // Not putting in use
    
    // MARK: Developer
    var logLevel = GSLogLevel.none
    
    // MARK: Misc
    var autoRefresh = true
}

class GlobalSettingsViewModel: ObservableObject {
    @Published var settings: GlobalSettings 
    {
        didSet { validate() }
    }
    
    @Published var selection = 0
    
    @Published var isFirstLaunch = UserDefaults.standard.value(forKey: "IsFirstLaunch") as? Bool ?? true
    
    var didFinishLaunchingNotificationCancellable: Cancellable?
    var didActivateApplicationNotificationCancellable: Cancellable?
    var didCurrentWallpaperChangeCancellable: Cancellable?
    var didAddToLoginItemCancellable: Cancellable?
    var didChangeAdjustMenuBarTintCancellable: Cancellable?
    var visibilityObservers = [NSObjectProtocol]()
    
    /// Why the wallpaper cannot be seen (or should save power) right now, and what was done about it
    enum HiddenReason { case displayAsleep, locked, fullscreen, battery }
    private var hiddenReasons = Set<HiddenReason>()
    private var autoPaused = false
    private var autoMuted = false
    
    init() {
        if let data = UserDefaults.standard.data(forKey: "GlobalSettings"),
           let settings = try? JSONDecoder().decode(GlobalSettings.self, from: data) {
            self.settings = settings
        } else {
            self.settings = GlobalSettings()
        }
        
        // Add observers
        self.didFinishLaunchingNotificationCancellable =
        NotificationCenter.default.publisher(for: NSApplication.didFinishLaunchingNotification)
            .sink { [weak self] _ in self?.didFinishLaunchingNotification() }
    }
    
    deinit {
        didActivateApplicationNotificationCancellable?.cancel()
        didFinishLaunchingNotificationCancellable?.cancel()
        didCurrentWallpaperChangeCancellable?.cancel()
        didAddToLoginItemCancellable?.cancel()
        didChangeAdjustMenuBarTintCancellable?.cancel()
    }
    
    func didFinishLaunchingNotification() {
        self.didActivateApplicationNotificationCancellable =
        NotificationCenter.default.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in self?.activateApplicationDidChange() }
        
        self.didCurrentWallpaperChangeCancellable =
        AppDelegate.shared.wallpaperViewModel.$currentWallpaper
            .sink { [weak self] in self?.didCurrentWallpaperChange($0) }
        
        self.didAddToLoginItemCancellable =
        self.$settings
            .removeDuplicates { $0.autoStart == $1.autoStart }
            .map { $0.autoStart }
            .sink { [weak self] in self?.didAddToLoginItem($0) }
        
        self.didChangeAdjustMenuBarTintCancellable =
        self.$settings
            .removeDuplicates { $0.adjustMenuBarTint == $1.adjustMenuBarTint }
            .map { $0.adjustMenuBarTint }
            .sink { [weak self] in self?.didChangeAdjustMenuBarTint($0) }
            
        observeVisibility()
        
        self.validate()
    }
    
    func didAddToLoginItem(_ added: Bool) {
        guard !isFirstLaunch else { return } // asked on the first launch screen
        let appService = SMAppService.mainApp
        do {
            if added {
                try appService.register()
            } else {
                try appService.unregister()
            }
        } catch {
            print(error)
        }
    }
    
    func didChangeAdjustMenuBarTint(_ newValue: Bool) {
        guard !isFirstLaunch else { return }
        if newValue != true {
            if let wallpaper = UserDefaults.standard.url(forKey: "OSWallpaper") {
                try? NSWorkspace.shared.setDesktopImageURL(wallpaper, for: .main!)
            }
        } else {
            do {
                let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "staticWP_\(AppDelegate.shared.wallpaperViewModel.currentWallpaper.wallpaperDirectory.hashValue).tiff")
                try NSWorkspace.shared.setDesktopImageURL(url, for: .main!)
            } catch {
                print(error)
            }
        }
    }
    
    func didCurrentWallpaperChange(_ newValue: WEWallpaper) {
        AppDelegate.shared.setPlacehoderWallpaper(with: newValue)
    }
    
    func reset() {
        settings = (try? JSONDecoder()
            .decode(GlobalSettings.self,
                from: UserDefaults.standard.data(forKey: "GlobalSettings")
            ?? Data()))
        ?? GlobalSettings()
    }
    
    func save() {
        let data = try! JSONEncoder().encode(settings)
        print(String(describing: String(data: data, encoding: .utf8)))
        UserDefaults.standard.set(data, forKey: "GlobalSettings")
    }
    
    func setQuality(_ quality: GSQuality) {
        switch quality {
        case .low:
            self.settings.antiAliasing = .none
            self.settings.postProcessing = .disabled
            self.settings.textureResolution = .highQuality
            self.settings.fps = 10
            self.settings.reflections = false
        case .medium:
            self.settings.antiAliasing = .none
            self.settings.postProcessing = .enabled
            self.settings.textureResolution = .highQuality
            self.settings.fps = 15
            self.settings.reflections = true
        case .high:
            self.settings.antiAliasing = .msaa_x2
            self.settings.postProcessing = .enabled
            self.settings.textureResolution = .highQuality
            self.settings.fps = 25
            self.settings.reflections = true
        case .ultra:
            self.settings.antiAliasing = .msaa_x2
            self.settings.postProcessing = .ultra
            self.settings.textureResolution = .highQuality
            self.settings.fps = 30
            self.settings.reflections = true
        }
    }
    
    private func validate() {
        switch settings.appearance {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .followSystem:
            NSApp.appearance = nil
        }
    }
    
    func activateApplicationDidChange() {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return }
        
        switch frontmostApplication.bundleIdentifier {
        case "com.apple.finder":
            fallthrough
        case "\(Bundle.main.bundleIdentifier!)":
            globalSettingsWhenApplicationDidBecomeActive()
        default:
            switch self.settings.otherApplicationFocused {
            case .mute:
                AppDelegate.shared.mute()
            case .pause:
                AppDelegate.shared.pause()
            case .keepRunning:
                fallthrough
            default:
                return
            }
        }
    }
    
    private func observeVisibility() {
        let workspace = NSWorkspace.shared.notificationCenter
        let observe = { (center: NotificationCenter, name: Notification.Name, reason: HiddenReason, hidden: Bool) in
            self.visibilityObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.setHidden(hidden, because: reason)
            })
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification, .displayAsleep, true)
        observe(workspace, NSWorkspace.screensDidWakeNotification, .displayAsleep, false)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, .locked, true)
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, .locked, false)
        observe(DistributedNotificationCenter.default(), .init("com.apple.screenIsLocked"), .locked, true)
        observe(DistributedNotificationCenter.default(), .init("com.apple.screenIsUnlocked"), .locked, false)
        // power source changes (plugged / unplugged)
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            AppDelegate.shared.globalSettingsViewModel.setHidden(GlobalSettingsViewModel.isOnBattery, because: .battery)
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        setHidden(Self.isOnBattery, because: .battery)
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            visibilityObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // the window list is updated once the Space animation ends
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self?.setHidden(Self.isFullscreenAppInFront(), because: .fullscreen)
                }
            })
        }
    }
    
    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return type as String == kIOPSBatteryPowerValue
    }
    
    /// A window of the frontmost app covers the whole main screen (a full screen app in its own Space)
    static func isFullscreenAppInFront() -> Bool {
        guard let screen = NSScreen.screens.first, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid(),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return windows.contains { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String].flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) })
            else { return false }
            return bounds.size == screen.frame.size
        }
    }
    
    /// Pauses or mutes the wallpaper while it cannot be seen, as chosen in the Performance settings
    func setHidden(_ hidden: Bool, because reason: HiddenReason) {
        if hidden { hiddenReasons.insert(reason) } else { hiddenReasons.remove(reason) }
        let actions = hiddenReasons.map { reason in
            switch reason {
            case .fullscreen: settings.otherApplicationFullscreen
            case .battery: settings.laptopOnBattery
            default: settings.displayAsleep
            }
        }
        let pause = actions.contains(.pause) || actions.contains(.stop)
        let mute = actions.contains(.mute)
        let wallpaper = AppDelegate.shared.wallpaperViewModel
        if pause != autoPaused {
            // a wallpaper the user paused stays paused
            if pause, wallpaper.playRate != 0 { AppDelegate.shared.pause(); autoPaused = true }
            if !pause { AppDelegate.shared.resume(); autoPaused = false }
        }
        if mute != autoMuted {
            if mute, wallpaper.playVolume != 0 { AppDelegate.shared.mute(); autoMuted = true }
            if !mute { AppDelegate.shared.unmute(); autoMuted = false }
        }
    }
    
    func globalSettingsWhenApplicationDidBecomeActive() {
        switch self.settings.otherApplicationFocused {
        case .mute:
            AppDelegate.shared.unmute()
        case .pause:
            AppDelegate.shared.resume()
        case .keepRunning:
            fallthrough
        default:
            return
        }
    }
    
    private func saveAndValidate() {
        save()
        validate()
    }
}
