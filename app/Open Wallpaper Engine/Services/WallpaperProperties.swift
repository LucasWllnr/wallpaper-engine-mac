//
//  WallpaperProperties.swift
//  Open Wallpaper Engine
//
//  User properties of a wallpaper (project.json → general.properties: checkboxes, sliders, colors,
//  combos, text). Changed values are stored per wallpaper and handed to every renderer: the faithful
//  scene engine (--set-property), the built-in scene renderer ("user" bindings) and web wallpapers
//  (wallpaperPropertyListener.applyUserProperties).
//

import AppKit

struct WallpaperProperty: Identifiable {
    enum Kind { case bool, slider, color, combo, text, textInput }

    let key: String
    let label: String
    let kind: Kind
    let order: Int
    let defaultValue: Any
    var min = 0.0, max = 1.0, step = 0.0
    var options = [(label: String, value: String)]()

    var id: String { key }
}

enum WallpaperProperties {
    static let didChange = Notification.Name("WallpaperPropertiesDidChange")
    private static let storeKey = "WallpaperProperties"

    /// Editable properties declared by the wallpaper, in Wallpaper Engine's order
    static func list(for directory: URL) -> [WallpaperProperty] {
        guard let data = try? Data(contentsOf: directory.appending(path: "project.json")),
              let project = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let general = project["general"] as? [String: Any],
              let properties = general["properties"] as? [String: Any] else { return [] }

        return properties.compactMap { key, raw -> WallpaperProperty? in
            guard let info = raw as? [String: Any], let type = (info["type"] as? String)?.lowercased() else { return nil }
            let kind: WallpaperProperty.Kind
            switch type {
            case "bool": kind = .bool
            case "slider": kind = .slider
            case "color": kind = .color
            case "combo": kind = .combo
            case "text": kind = .text
            case "textinput": kind = .textInput
            default: return nil
            }
            var property = WallpaperProperty(key: key, label: label(info["text"] as? String ?? key), kind: kind,
                                             order: (info["order"] as? NSNumber)?.intValue ?? 0,
                                             defaultValue: info["value"] ?? "")
            property.min = (info["min"] as? NSNumber)?.doubleValue ?? 0
            property.max = (info["max"] as? NSNumber)?.doubleValue ?? 1
            property.step = (info["step"] as? NSNumber)?.doubleValue ?? ((info["precision"] as? NSNumber)?.intValue == 0 ? 1 : 0)
            property.options = (info["options"] as? [[String: Any]] ?? []).map {
                (label: label(($0["label"] as? String) ?? ""), value: stringValue($0["value"]))
            }
            return property
        }
        .sorted { ($0.order, $0.label) < ($1.order, $1.label) }
    }

    /// Default values merged with the user's changes
    static func values(for directory: URL) -> [String: Any] {
        var result = [String: Any]()
        for property in list(for: directory) { result[property.key] = property.defaultValue }
        return result.merging(overrides(for: directory)) { $1 }
    }

    static func overrides(for directory: URL) -> [String: Any] {
        (UserDefaults.standard.dictionary(forKey: storeKey)?[directory.lastPathComponent] as? [String: Any]) ?? [:]
    }

    static func set(_ value: Any, for key: String, in directory: URL) {
        var values = overrides(for: directory)
        values[key] = value
        setOverrides(values, for: directory)
    }

    static func reset(_ directory: URL) {
        setOverrides(nil, for: directory)
    }

    private static func setOverrides(_ values: [String: Any]?, for directory: URL) {
        var store = UserDefaults.standard.dictionary(forKey: storeKey) ?? [:]
        store[directory.lastPathComponent] = values
        UserDefaults.standard.set(store, forKey: storeKey)
        NotificationCenter.default.post(name: didChange, object: directory)
    }

    // MARK: Presets: the changed values as {"key": value}

    static func preset(of directory: URL) -> Data {
        (try? JSONSerialization.data(withJSONObject: overrides(for: directory), options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }

    /// Applies the values of a preset that this wallpaper declares; false when the data is not a preset
    @discardableResult
    static func load(preset data: Data, into directory: URL) -> Bool {
        guard let preset = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        // also accept {"key": {"value": …}}, the shape web wallpapers receive
        let values = preset.mapValues { ($0 as? [String: Any])?["value"] ?? $0 }
        let keys = Set(list(for: directory).map(\.key))
        setOverrides(overrides(for: directory).merging(values.filter { keys.contains($0.key) }) { $1 }, for: directory)
        return true
    }

    /// Copies this wallpaper's changed values to every other wallpaper declaring the same properties
    static func applyToAll(from directory: URL, to others: [URL]) {
        let data = preset(of: directory)
        for other in others where other != directory && !list(for: other).isEmpty {
            load(preset: data, into: other)
        }
    }

    /// --set-property arguments for the faithful scene engine (only changed values)
    static func engineArguments(for directory: URL) -> [String] {
        overrides(for: directory).flatMap { key, value -> [String] in
            let text = (value as? Bool).map { $0 ? "1" : "0" } ?? stringValue(value)
            return ["--set-property", "\(key)=\(text)"]
        }
    }

    /// {"key": {"value": …}} as expected by wallpaperPropertyListener.applyUserProperties
    static func webPayload(for directory: URL) -> String {
        let wrapped = values(for: directory).mapValues { ["value": $0] }
        guard let data = try? JSONSerialization.data(withJSONObject: wrapped) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func stringValue(_ any: Any?) -> String {
        switch any {
        case let value as String: value
        case let value as NSNumber: value.stringValue
        case nil: ""
        default: "\(any!)"
        }
    }

    /// Labels may be HTML or untranslated "ui_…" keys
    private static func label(_ text: String) -> String {
        let plain = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard plain.hasPrefix("ui_") else { return plain }
        return plain.replacingOccurrences(of: "ui_browse_properties_", with: "")
            .replacingOccurrences(of: "ui_", with: "")
            .replacingOccurrences(of: "_", with: " ").capitalized
    }
}
