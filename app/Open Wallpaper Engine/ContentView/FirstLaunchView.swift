//
//  FirstLaunchView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/4.
//

import SwiftUI

/// First launch: what the app needs, each permission answered Yes or No before anything is turned on
struct FirstLaunchView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var globalSettingsViewModel: GlobalSettingsViewModel
    
    @State private var openAtLogin: Bool?
    @State private var desktopPicture: Bool?
    @State private var useSteam: Bool?
    @State private var assets = WEAssets.directory
    
    private var isSteamInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.valvesoftware.steam") != nil
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Open Wallpaper Engine")
                .font(.largeTitle)
            Text("Animated wallpapers from the Wallpaper Engine Workshop. You need Steam for Mac, signed in to an account that owns Wallpaper Engine.")
                .foregroundStyle(.secondary)
            if !isSteamInstalled {
                Label("Steam for Mac is not installed. Get it from store.steampowered.com, then come back.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Divider()
            Text("Do you allow Open Wallpaper Engine to:").font(.title3).bold()
            question("Open at login", "So your wallpaper is back after you restart the Mac.",
                     systemImage: "power", answer: $openAtLogin)
            question("Change the macOS desktop picture", "A still of the animated wallpaper becomes the desktop picture, so the menu bar takes its colors. Your own picture is put back when the app quits.",
                     systemImage: "menubar.rectangle", answer: $desktopPicture)
            question("Use Steam", "Browse the Workshop (steamcommunity.com), subscribe and unsubscribe with your account. Steam may be started in the background.",
                     systemImage: "cloud.fill", answer: $useSteam)
            Divider()
            HStack(alignment: .top) {
                Image(systemName: assets == nil ? "cube.transparent" : "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(assets == nil ? Color.secondary : Color.green)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Faithful scene rendering (optional)").bold()
                    if assets == nil {
                        Text("Scenes look exactly like on Windows with Wallpaper Engine's own files (≈ 800 MB). Steam downloads them from its console: the command is copied, paste it there and press Return. Without them, scenes use a simpler built-in renderer.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Copy the command and open the Steam console") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(WEAssets.downloadCommand, forType: .string)
                                NSWorkspace.shared.open(URL(string: "steam://open/console")!)
                            }
                            Button("Check again") { assets = WEAssets.directory }
                        }
                    } else {
                        Text("Wallpaper Engine's files were found.").foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button {
                    finish()
                } label: {
                    Text("Continue").frame(width: 100)
                }
                .buttonStyle(.borderedProminent)
                .disabled(openAtLogin == nil || desktopPicture == nil || useSteam == nil)
            }
        }
        .padding(24)
        .frame(width: 620)
        .interactiveDismissDisabled()
    }
    
    private func question(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, systemImage: String, answer: Binding<Bool?>) -> some View {
        HStack(alignment: .top) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Picker("", selection: answer) {
                Text("Yes").tag(Bool?.some(true))
                Text("No").tag(Bool?.some(false))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
        }
    }
    
    private func finish() {
        globalSettingsViewModel.settings.autoStart = openAtLogin ?? false
        globalSettingsViewModel.settings.adjustMenuBarTint = desktopPicture ?? false
        SteamWorkshopBridge.isAllowed = useSteam ?? false
        globalSettingsViewModel.save()
        UserDefaults.standard.set(false, forKey: "IsFirstLaunch")
        globalSettingsViewModel.isFirstLaunch = false
        // nothing was applied while the answers were pending
        globalSettingsViewModel.didAddToLoginItem(globalSettingsViewModel.settings.autoStart)
        AppDelegate.shared.setPlacehoderWallpaper(with: AppDelegate.shared.wallpaperViewModel.currentWallpaper)
        dismiss()
    }
}

extension FirstLaunchView {
    struct NewSection: View {
        var title: LocalizedStringKey
        var text: LocalizedStringKey
        var textColor: Color = .primary
        var systemImage: String
        var imageColor: Color = .accentColor
        
        var body: some View {
            HStack {
                Image(systemName: systemImage)
                    .frame(width: 50, height: 50)
                    .font(.largeTitle)
                    .foregroundStyle(imageColor)
                VStack(alignment: .leading) {
                    Text(title)
                        .foregroundStyle(textColor)
                        .font(.title2)
                        .bold()
                    Text(text)
                        .foregroundStyle(textColor)
                }
                .multilineTextAlignment(.leading)
                Spacer()
            }
        }
    }
}

extension AppDelegate {
    @objc func resetFirstLaunch() {
        UserDefaults.standard.set(true, forKey: "IsFirstLaunch")
    }
}

struct FirstLaunchView_Previews: PreviewProvider {
    static var previews: some View {
        FirstLaunchView()
    }
}
