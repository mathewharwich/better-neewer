import Foundation
import Combine

enum LightKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case cb200b, cb60b, cb60rgb
    var id: String { rawValue }
    var name: String {
        switch self { case .cb200b: "CB200B"; case .cb60b: "CB60B"; case .cb60rgb: "CB60 RGB" }
    }
    var subtitle: String { self == .cb60rgb ? "RGB" : "Bi-color" }
    var symbol: String { self == .cb60rgb ? "circle.lefthalf.filled" : "lightbulb" }
    var supportsColor: Bool { self == .cb60rgb }
    var supportsBoost: Bool { self == .cb200b }
    var rawNamePrefix: String {
        switch self { case .cb200b: "NW-20210037"; case .cb60b: "NW-20220014"; case .cb60rgb: "NW-20210012" }
    }
    static func detect(name: String?) -> LightKind? {
        guard let name = name?.uppercased() else { return nil }
        return allCases.first { name == $0.rawNamePrefix || name.hasPrefix($0.rawNamePrefix + "&") }
    }
}

struct DiscoveredLight: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: LightKind
    let advertisedName: String
    var rssi: Int?
    var mac: [UInt8]?
}

enum ControlMode: String, CaseIterable, Codable, Identifiable {
    case white = "White", color = "Color", effects = "Effects"
    var id: String { rawValue }
}

enum LightConnection: String {
    case disconnected, connecting, discovering, connected
    var label: String {
        switch self {
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .discovering: "Reading light…"
        case .connected: "Connected"
        }
    }
}

struct RememberedSettings: Codable, Equatable {
    var brightness = 50.0
    var kelvin = 4500.0
    var tint = 0.0
    var hue = 30.0
    var saturation = 80.0
    var mode: ControlMode = .white
    var effectID = 1
    var speed = 5.0
    var brightnessUpper = 100.0
    var kelvinUpper = 6500.0
    var hueUpper = 360.0
    var sparks = 5.0
    var colorOption = 0

    // Neutral local defaults, never replayed automatically to a light.
    static func initial(for kind: LightKind) -> RememberedSettings {
        RememberedSettings()
    }
}

@MainActor
final class LightState: ObservableObject, Identifiable {
    nonisolated let kind: LightKind
    nonisolated let id: UUID
    nonisolated let advertisedName: String
    @Published var mac: [UInt8]?
    @Published var identityConfirmed = false
    var hasRememberedSettings: Bool
    @Published var displayName: String
    @Published var connection: LightConnection = .disconnected
    @Published var reportedPower: Bool?
    @Published var reportedBoost: Bool?
    @Published var requestedPower: Bool?
    @Published var requestedBoost: Bool?
    @Published var firmware: String?
    @Published var settings: RememberedSettings
    @Published var valuesLabel = "Remembered values"
    @Published var message: String?
    @Published var error: String?
    @Published var hasBeenSeen = false
    @Published var isSending = false
    var canControl: Bool { connection == .connected && identityConfirmed && NeewerIdentity.isValidMAC(mac) }
    var canBoost: Bool { canControl && kind.supportsBoost && firmware == "1.1.5" }

    init(id: UUID, kind: LightKind, advertisedName: String, mac: [UInt8]? = nil, settings: RememberedSettings? = nil, name: String? = nil) {
        self.id = id
        self.kind = kind
        self.advertisedName = advertisedName
        self.mac = NeewerIdentity.isValidMAC(mac) ? mac : nil
        self.hasRememberedSettings = settings != nil
        self.displayName = name ?? kind.name
        self.settings = settings ?? .initial(for: kind)
        self.valuesLabel = settings == nil ? "Default values" : "Remembered values"
    }

    func accepts(identifier: UUID, name: String?) -> Bool {
        identifier == id && name == advertisedName && LightKind.detect(name: name) == kind
    }
}

enum EffectParameter: String, Hashable {
    case brightness, brightnessUpper, temperature, temperatureUpper, tint, hue, hueUpper, saturation, speed, sparks, color
}

struct EffectDefinition: Identifiable {
    let id: Int
    let name: String
    let parameters: Set<EffectParameter>
    var colorOptions: [String] = []
}
