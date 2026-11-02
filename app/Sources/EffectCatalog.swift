import Foundation

// Capability facts independently transcribed from Control Center 3.5.4's
// CB60B, CB200B, and CB60 RGB profiles. IDs are the 1-based wire effect IDs
// (the vendor profile's sceneTag + 1), not positions in this filtered array.
// Color-option labels are corroborated by NeewerLite's pinned fx17_mac preset.
enum EffectCatalog {
    static func effects(for kind: LightKind) -> [EffectDefinition] {
        let rgb = kind.supportsColor
        let white: Set<EffectParameter> = [.brightness, .temperature, .speed]
        let tinted = white.union(rgb ? [.tint] : [])
        let range: Set<EffectParameter> = [.brightness, .brightnessUpper, .temperature, .speed]
        let tintedRange = range.union(rgb ? [.tint] : [])
        var effects: [EffectDefinition] = [
            .init(id: 1, name: "Lightning", parameters: white),
            .init(id: 2, name: "Paparazzi", parameters: tinted),
            .init(id: 3, name: "Defective bulb", parameters: tinted),
            .init(id: 4, name: "Explosion", parameters: tinted.union([.sparks])),
            .init(id: 5, name: "Welding", parameters: tintedRange),
            .init(id: 6, name: "White flash", parameters: tinted),
            .init(id: 8, name: "White pulse", parameters: tinted),
            .init(id: 11, name: "Candlelight", parameters: tintedRange.union([.sparks])),
            .init(id: 13, name: "Temperature loop", parameters: [.brightness, .temperature, .temperatureUpper, .speed]),
            .init(id: 14, name: "Brightness loop",
                  parameters: rgb ? [.brightness, .brightnessUpper, .temperature, .hue, .speed, .color] : range,
                  colorOptions: rgb ? ["White", "Color"] : []),
            .init(id: 15, name: "TV screen", parameters: tintedRange),
            .init(id: 16, name: "Fireworks",
                  parameters: rgb ? [.brightness, .color, .speed, .sparks] : [.brightness, .speed, .sparks],
                  colorOptions: rgb ? ["Single color", "Color", "Combined"] : [])
        ]
        if rgb {
            effects += [
                .init(id: 7, name: "Color flash", parameters: [.brightness, .hue, .saturation, .speed]),
                .init(id: 9, name: "Color pulse", parameters: [.brightness, .hue, .saturation, .speed]),
                .init(id: 10, name: "Police car", parameters: [.brightness, .color, .speed],
                      colorOptions: ["Red", "Blue", "Red and blue", "White and blue", "Red, blue and white"]),
                .init(id: 12, name: "Hue loop", parameters: [.brightness, .hue, .hueUpper, .speed]),
                .init(id: 17, name: "Party", parameters: [.brightness, .color, .speed],
                      colorOptions: ["Single color", "Color", "Combined"])
            ]
        }
        return effects.sorted { $0.id < $1.id }
    }
}
