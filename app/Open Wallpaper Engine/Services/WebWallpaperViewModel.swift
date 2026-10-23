//
//  WebWallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Toby on 2023/8/28.
//

import WebKit
import SwiftUI

class WebWallpaperViewModel: NSObject, ObservableObject, WKNavigationDelegate {
    var currentWallpaper: WEWallpaper
    private weak var webView: WKWebView?
    
    var fileUrl: URL {
        currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file)
    }
    
    var readAccessURL: URL {
        currentWallpaper.wallpaperDirectory
    }
    
    init(wallpaper: WEWallpaper) {
        self.currentWallpaper = wallpaper
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillSleep(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(propertiesDidChange(_:)), name: WallpaperProperties.didChange, object: nil)
    }

    @objc private func propertiesDidChange(_ notification: Notification) {
        guard let webView, notification.object as? URL == currentWallpaper.wallpaperDirectory else { return }
        applyUserProperties(to: webView)
    }

    /// Hands the wallpaper's property values to its page, as Wallpaper Engine does
    private func applyUserProperties(to webView: WKWebView) {
        let payload = WallpaperProperties.webPayload(for: currentWallpaper.wallpaperDirectory)
        webView.evaluateJavaScript("window.wallpaperPropertyListener && window.wallpaperPropertyListener.applyUserProperties && window.wallpaperPropertyListener.applyUserProperties(\(payload));", completionHandler: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.webView = webView
        applyUserProperties(to: webView)
        let javascriptStyle = "var css = '*{-webkit-touch-callout:none;-webkit-user-select:none}'; var head = document.head || document.getElementsByTagName('head')[0]; var style = document.createElement('style'); style.type = 'text/css'; style.appendChild(document.createTextNode(css)); head.appendChild(style);"
        webView.evaluateJavaScript(javascriptStyle, completionHandler: nil)
        
        if AppDelegate.shared.globalSettingsViewModel.settings.adjustMenuBarTint {
            // right after didFinish the page has often not drawn yet (blank snapshot)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak webView] in
                webView?.takeSnapshot(with: nil) { nsImage, _ in
                    guard let self, let tiff = nsImage?.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                    let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                        .appending(path: "staticWP_\(self.currentWallpaper.wallpaperDirectory.lastPathComponent).png")
                    guard (try? png.write(to: url, options: .atomic)) != nil else { return }
                    AppDelegate.shared.setDesktopPicture(url)
                }
            }
        }
    }
    
    @objc func systemWillSleep(_ notification: Notification) {
        // Handle going to sleep
        print("System is going to sleep")
        // Update your SwiftUI state here if needed
    }
        
    @objc func systemDidWake(_ notification: Notification) {
        // Handle waking up
        print("System woke up from sleep")
        // Update your SwiftUI state here if needed
    }
}
