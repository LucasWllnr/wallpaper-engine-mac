//
//  WallpaperPropertiesView.swift
//  Open Wallpaper Engine
//
//  Editor for a wallpaper's user properties (see WallpaperProperties), shown in the preview sidebar.
//

import SwiftUI

struct WallpaperPropertiesView: View {
    let directory: URL

    @State private var properties = [WallpaperProperty]()
    @State private var values = [String: Any]()

    var body: some View {
        VStack(spacing: 12) {
            if properties.isEmpty {
                Text("No editable properties")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(properties) { property in
                row(property)
            }
            if !properties.isEmpty {
                Button {
                    WallpaperProperties.reset(directory)
                    reload()
                } label: {
                    Label("Reset", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: directory) { _ in reload() }
    }

    @ViewBuilder
    private func row(_ property: WallpaperProperty) -> some View {
        switch property.kind {
        case .text:
            Text(property.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .bool:
            Toggle(isOn: Binding(get: { boolValue(property) }, set: { commit(property, $0) })) {
                Text(property.label).frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
        case .slider:
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(property.label)
                    Spacer()
                    Text(String(format: property.step >= 1 ? "%.0f" : "%.2f", numberValue(property)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                // the wallpaper reloads only when the slider is released
                Slider(value: Binding(get: { numberValue(property) }, set: { values[property.key] = $0 }),
                       in: property.min...max(property.max, property.min + 0.001)) { editing in
                    if !editing { commit(property, numberValue(property)) }
                }
            }
        case .color:
            ColorPicker(selection: Binding(get: { colorValue(property) }, set: { commitColor(property, $0) }),
                        supportsOpacity: false) {
                Text(property.label).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .combo:
            Picker(property.label, selection: Binding(get: { WallpaperProperties.stringValue(values[property.key]) },
                                                      set: { commit(property, $0) })) {
                ForEach(property.options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
        case .textInput:
            TextField(property.label, text: Binding(get: { WallpaperProperties.stringValue(values[property.key]) },
                                                    set: { values[property.key] = $0 }))
                .onSubmit { commit(property, WallpaperProperties.stringValue(values[property.key])) }
        }
    }

    private func reload() {
        properties = WallpaperProperties.list(for: directory)
        values = WallpaperProperties.values(for: directory)
    }

    private func commit(_ property: WallpaperProperty, _ value: Any) {
        values[property.key] = value
        WallpaperProperties.set(value, for: property.key, in: directory)
    }

    private func boolValue(_ property: WallpaperProperty) -> Bool {
        switch values[property.key] {
        case let value as Bool: value
        case let value as NSNumber: value.boolValue
        case let value as String: value == "1" || value.lowercased() == "true"
        default: false
        }
    }

    private func numberValue(_ property: WallpaperProperty) -> Double {
        switch values[property.key] {
        case let value as NSNumber: value.doubleValue
        case let value as Double: value
        case let value as String: Double(value) ?? property.min
        default: property.min
        }
    }

    /// Wallpaper Engine colors are "r g b" with components in 0…1
    private func colorValue(_ property: WallpaperProperty) -> Color {
        let parts = WallpaperProperties.stringValue(values[property.key])
            .split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        guard parts.count >= 3 else { return .white }
        return Color(.sRGB, red: parts[0], green: parts[1], blue: parts[2])
    }

    private func commitColor(_ property: WallpaperProperty, _ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
        commit(property, String(format: "%.5f %.5f %.5f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent))
    }
}
