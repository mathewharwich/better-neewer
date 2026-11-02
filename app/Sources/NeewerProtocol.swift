import Foundation

enum NeewerIdentity {
    static func isValidMAC(_ bytes: [UInt8]?) -> Bool {
        guard let bytes, bytes.count == 6 else { return false }
        return bytes.contains { $0 != 0 } && bytes.contains { $0 != 255 }
    }

    static func parseMAC(_ text: String) -> [UInt8]? {
        let pieces = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 6, pieces.allSatisfy({ $0.count == 2 }) else { return nil }
        let bytes = pieces.compactMap { UInt8($0, radix: 16) }
        return isValidMAC(bytes) ? bytes : nil
    }

    enum Resolution: Equatable, Sendable { case found([UInt8]), missing, ambiguous }

    // CoreBluetooth identifiers are not MAC addresses. Independent implementation
    // of the local metadata mechanism documented in pinned NeewerLite:
    // https://github.com/keefo/NeewerLite/blob/6450b89580959b7a07911d5684246ec0b2b74ffb/NeewerLite/NeewerLite/Common/CBCharacteristicExtensions.swift#L30
    // This JSON variant reads only connected entries matching one exact raw name.
    // It retains no metadata for other Bluetooth devices.
    static func resolve(profilerJSON data: Data, exactName: String) -> Resolution {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return .missing }
        var matches = Set<Data>()
        var invalidMatch = false
        for controller in controllers {
            for item in controller["device_connected"] as? [[String: Any]] ?? [] {
                guard let device = item[exactName] as? [String: Any] else { continue }
                guard let text = device["device_address"] as? String, let mac = parseMAC(text) else {
                    invalidMatch = true; continue
                }
                matches.insert(Data(mac))
            }
        }
        if matches.count > 1 { return .ambiguous }
        if invalidMatch { return matches.isEmpty ? .missing : .ambiguous }
        if let match = matches.first { return .found(Array(match)) }
        return .missing
    }
}

// Primary wire references (reviewed; no vendor binary code is embedded):
// https://github.com/verygeeky/neewer-hardware/blob/9ecdad9c18eb29e9f198a29816e2616b79b3681a/protocol.md
// https://github.com/verygeeky/neewer-python/blob/aa63b7bf024f565767b2bf1c9b7cafb6222a96b0/neewer/protocol/frames.py
// White/HSI payloads additionally checked against installed Control Center 3.5.4
// publishBleCCTWithData / publishBleHSIWithData. Direct tube payloads differ.

enum NeewerProtocolError: LocalizedError {
    case unsupported(String)
    case invalidValue(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let text), .invalidValue(let text): return text
        }
    }
}

enum NeewerQuery: String { case state, version, boost }

enum NeewerCommand {
    case query(NeewerQuery)
    case power(Bool)
    case boost(Bool)
    case white(RememberedSettings, curve: UInt8)
    case color(RememberedSettings)
    case effect(RememberedSettings)

    var label: String {
        switch self {
        case .query(let query): return "Read \(query.rawValue)"
        case .power(let on): return on ? "Power on" : "Power off"
        case .boost(let enabled): return enabled ? "Boost enabled" : "Boost disabled"
        case .white: return "White controls"
        case .color: return "Color controls"
        case .effect: return "Effect controls"
        }
    }
    var isValueSetting: Bool {
        switch self { case .white, .color, .effect: return true; default: return false }
    }
    var verification: NeewerQuery? {
        switch self { case .query: return nil; case .boost: return .boost; default: return .state }
    }
    func packet(for kind: LightKind, mac: [UInt8]) throws -> Data {
        guard NeewerIdentity.isValidMAC(mac) else { throw NeewerProtocolError.invalidValue("The light's Bluetooth address has not been resolved.") }
        switch self {
        case .query(.state): return NeewerWire.frame(0x8E, mac + [0x85])
        case .query(.version): return NeewerWire.frame(0x9E, mac)
        case .query(.boost):
            guard kind.supportsBoost else { throw NeewerProtocolError.unsupported("This light has no Boost query.") }
            return NeewerWire.frame(0xAC, mac)
        case .power(let on): return NeewerWire.frame(0x8D, mac + [0x81, on ? 1 : 2])
        case .boost(let enabled):
            guard kind.supportsBoost else { throw NeewerProtocolError.unsupported("This light has no Boost control.") }
            return NeewerWire.frame(0xAB, mac + [enabled ? 1 : 2])
        case .white(let values, let curve):
            let brightness = try NeewerWire.byte(values.brightness, 0...100, "brightness")
            let cct = try NeewerWire.byte(values.kelvin / 100, 27...65, "temperature")
            let tint = try NeewerWire.byte((kind.supportsColor ? values.tint : 0) + 50, 0...100, "tint")
            return NeewerWire.frame(0x90, mac + [0x87, brightness, cct, tint, curve, 0])
        case .color(let values):
            guard kind.supportsColor else { throw NeewerProtocolError.unsupported("This light supports white light only.") }
            let hue = try NeewerWire.integer(values.hue, 0...360, "hue")
            let saturation = try NeewerWire.byte(values.saturation, 0...100, "saturation")
            let brightness = try NeewerWire.byte(values.brightness, 0...100, "brightness")
            return NeewerWire.frame(0x8F, mac + [0x86, UInt8(hue & 255), UInt8(hue >> 8), saturation, brightness, 0])
        case .effect(let values):
            let parameters = try NeewerEffectCodec.parameters(values, for: kind)
            return NeewerWire.frame(0x91, mac + [0x8B, UInt8(values.effectID)] + parameters)
        }
    }
}

enum NeewerWire {
    static func frame(_ opcode: UInt8, _ payload: [UInt8]) -> Data {
        precondition(payload.count <= 255)
        let bytes: [UInt8] = [0x78, opcode, UInt8(payload.count)] + payload
        return Data(bytes + [bytes.reduce(0, &+)])
    }
    static func integer(_ value: Double, _ range: ClosedRange<Int>, _ label: String) throws -> Int {
        guard value.isFinite else { throw NeewerProtocolError.invalidValue("Invalid \(label) value.") }
        return Int(min(Double(range.upperBound), max(Double(range.lowerBound), value)).rounded())
    }
    static func byte(_ value: Double, _ range: ClosedRange<Int>, _ label: String) throws -> UInt8 {
        UInt8(try integer(value, range, label))
    }
}

struct NeewerReplyFrame {
    let bytes: [UInt8]
    var opcode: UInt8 { bytes[1] }
    var payloadLength: Int { Int(bytes[2]) }
    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 4, bytes[0] == 0x78, bytes.count == Int(bytes[2]) + 4,
              bytes.dropLast().reduce(UInt8(0), &+) == bytes.last,
              Self.plausibleLength(opcode: bytes[1], length: Int(bytes[2])) else { return nil }
        self.bytes = bytes
    }
    static func plausibleLength(opcode: UInt8, length: Int) -> Bool {
        switch opcode {
        case 0x02: return length == 1
        case 0x04: return (8...64).contains(length) // includes optional mode/settings extension
        case 0x08: return (11...64).contains(length)
        case 0x11: return length == 7
        default: return length <= 128
        }
    }
}

struct NeewerStreamDecoder {
    private var buffer: [UInt8] = []
    mutating func receive(_ data: Data) -> [NeewerReplyFrame] {
        buffer += data
        var frames: [NeewerReplyFrame] = []
        while buffer.count >= 3 {
            guard buffer[0] == 0x78,
                  NeewerReplyFrame.plausibleLength(opcode: buffer[1], length: Int(buffer[2])) else {
                buffer.removeFirst(); continue
            }
            let total = Int(buffer[2]) + 4
            guard buffer.count >= total else { break }
            guard let frame = NeewerReplyFrame(Array(buffer.prefix(total))) else {
                buffer.removeFirst(); continue
            }
            buffer.removeFirst(total)
            frames.append(frame)
        }
        return frames
    }
}

struct NeewerReportedWhite {
    let brightness: Double
    let kelvin: Double
    let tint: Double
    let curve: UInt8
}

struct NeewerReportedColor {
    let brightness: Double
    let hue: Double
    let saturation: Double
}

enum NeewerReport {
    case power(Bool?)
    case firmware(String)
    case boost(Bool?, raw: UInt8)
    case white(NeewerReportedWhite)
    case color(NeewerReportedColor)
    case effect(id: Int, parameters: [UInt8])
}

enum NeewerReadback {
    static func reports(_ frame: NeewerReplyFrame, for kind: LightKind, mac: [UInt8]) -> [NeewerReport] {
        let b = frame.bytes
        guard NeewerIdentity.isValidMAC(mac), [UInt8(0x04), 0x08, 0x11].contains(frame.opcode),
              Array(b[3...8]) == mac else { return [] }
        switch frame.opcode {
        case 0x08: return [.firmware("\(b[11]).\(b[12]).\(b[13])")]
        case 0x11 where kind.supportsBoost:
            // Correlated physically on CB200B firmware 1.1.5.
            return [.boost(b[9] == 1 ? true : b[9] == 2 ? false : nil, raw: b[9])]
        case 0x04:
            var results: [NeewerReport] = [.power(b[10] == 1 ? true : b[10] == 2 ? false : nil)]
            // Short 8-byte payload has no control values. Never interpret its
            // checksum as mode, brightness, or any other field.
            if frame.payloadLength >= 14, b[11] == 1,
               b[12] <= 100, (27...65).contains(b[13]), b[14] <= 100, b[16] == 0 {
                results.append(.white(NeewerReportedWhite(brightness: Double(b[12]), kelvin: Double(b[13]) * 100,
                                                         tint: Double(Int(b[14]) - 50), curve: b[15])))
            }
            if frame.payloadLength >= 14, b[11] == 2, kind.supportsColor,
               Int(b[12]) + (Int(b[13]) << 8) <= 360, b[14] <= 100, b[15] <= 100, b[16] == 0 {
                results.append(.color(NeewerReportedColor(brightness: Double(b[15]), hue: Double(Int(b[12]) + (Int(b[13]) << 8)), saturation: Double(b[14]))))
            }
            if frame.payloadLength >= 10, b[11] == 3 {
                let id = Int(b[12])
                let parameters = Array(b[13..<(b.count - 1)])
                if NeewerEffectCodec.validParameters(parameters, id: id, kind: kind) {
                    results.append(.effect(id: id, parameters: parameters))
                }
            }
            return results
        default: return []
        }
    }
}

// Vendor publishBleSceneWithData: 0x91 / MAC6 / 0x8B / effectId / parameters.
// Effect14 explicitly carries white/color flag, both hue bytes, and CCT.
enum NeewerEffectCodec {
    static func parameters(_ values: RememberedSettings, for kind: LightKind) throws -> [UInt8] {
        guard EffectCatalog.effects(for: kind).contains(where: { $0.id == values.effectID }) else {
            throw NeewerProtocolError.unsupported("That effect is not supported by \(kind.name).")
        }
        let bri = try NeewerWire.byte(values.brightness, 0...100, "brightness")
        let upper = try NeewerWire.byte(values.brightnessUpper, 0...100, "upper brightness")
        let lowBri = min(bri, upper), highBri = max(bri, upper)
        let cct = try NeewerWire.byte(values.kelvin / 100, 27...65, "temperature")
        let cctUpper = try NeewerWire.byte(values.kelvinUpper / 100, 27...65, "upper temperature")
        let gm = try NeewerWire.byte((kind.supportsColor ? values.tint : 0) + 50, 0...100, "tint")
        let speed = try NeewerWire.byte(values.speed, 1...10, "speed")
        let sparks = try NeewerWire.byte(values.sparks, 1...10, "sparks")
        let hue = try NeewerWire.integer(values.hue, 0...360, "hue")
        let hueUpper = try NeewerWire.integer(values.hueUpper, 0...360, "upper hue")
        let sat = try NeewerWire.byte(values.saturation, 0...100, "saturation")
        func h(_ value: Int) -> [UInt8] { [UInt8(value & 255), UInt8(value >> 8)] }
        switch values.effectID {
        case 1: return [bri, cct, speed]
        case 2, 3, 6, 8: return [bri, cct, gm, speed]
        case 4: return [bri, cct, gm, speed, sparks]
        case 5, 15: return [lowBri, highBri, cct, gm, speed]
        case 7, 9: return [bri] + h(hue) + [sat, speed]
        case 10: return [bri, UInt8(min(4, max(0, values.colorOption))), speed]
        case 11: return [lowBri, highBri, cct, gm, speed, sparks]
        case 12: return [bri] + h(min(hue, hueUpper)) + h(max(hue, hueUpper)) + [speed]
        case 13: return [bri, min(cct, cctUpper), max(cct, cctUpper), speed]
        case 14:
            let flag: UInt8 = kind.supportsColor ? UInt8(min(1, max(0, values.colorOption))) : 0
            return [flag, lowBri, highBri] + h(flag == 1 ? hue : 0) + [cct, speed]
        case 16: return [bri, kind.supportsColor ? UInt8(min(2, max(0, values.colorOption))) : 0, speed, sparks]
        case 17: return [bri, UInt8(min(2, max(0, values.colorOption))), speed]
        default: throw NeewerProtocolError.unsupported("Unsupported effect.")
        }
    }

    static func validParameters(_ p: [UInt8], id: Int, kind: LightKind) -> Bool {
        guard EffectCatalog.effects(for: kind).contains(where: { $0.id == id }) else { return false }
        let count: Int
        switch id { case 1,10,17: count = 3; case 2,3,6,8,13,16: count = 4; case 4,5,7,9,15: count = 5; case 11,12: count = 6; case 14: count = 7; default: return false }
        guard p.count >= count else { return false }
        func bri(_ n: Int) -> Bool { p[n] <= 100 }
        func cct(_ n: Int) -> Bool { (27...65).contains(p[n]) }
        func gm(_ n: Int) -> Bool { p[n] <= 100 }
        func speed(_ n: Int) -> Bool { (1...10).contains(p[n]) }
        func hue(_ n: Int) -> Bool { Int(p[n]) + (Int(p[n + 1]) << 8) <= 360 }
        switch id {
        case 1: return bri(0) && cct(1) && speed(2)
        case 2,3,6,8: return bri(0) && cct(1) && gm(2) && speed(3)
        case 4: return bri(0) && cct(1) && gm(2) && speed(3) && speed(4)
        case 5,15: return bri(0) && bri(1) && p[0] <= p[1] && cct(2) && gm(3) && speed(4)
        case 7,9: return bri(0) && hue(1) && bri(3) && speed(4)
        case 10: return bri(0) && p[1] <= 4 && speed(2)
        case 11: return bri(0) && bri(1) && p[0] <= p[1] && cct(2) && gm(3) && speed(4) && speed(5)
        case 12: return bri(0) && hue(1) && hue(3) && Int(p[1]) + (Int(p[2]) << 8) <= Int(p[3]) + (Int(p[4]) << 8) && speed(5)
        case 13: return bri(0) && cct(1) && cct(2) && p[1] <= p[2] && speed(3)
        case 14: return p[0] <= (kind.supportsColor ? 1 : 0) && bri(1) && bri(2) && p[1] <= p[2] && hue(3) && cct(5) && speed(6)
        case 16: return bri(0) && p[1] <= (kind.supportsColor ? 2 : 0) && speed(2) && speed(3)
        case 17: return bri(0) && p[1] <= 2 && speed(2)
        default: return false
        }
    }

    static func merge(_ p: [UInt8], id: Int, kind: LightKind, into values: inout RememberedSettings) {
        guard validParameters(p, id: id, kind: kind) else { return }
        values.mode = .effects; values.effectID = id
        func hue(_ n: Int) -> Double { Double(Int(p[n]) + (Int(p[n + 1]) << 8)) }
        func tint(_ n: Int) { if kind.supportsColor { values.tint = Double(Int(p[n]) - 50) } }
        switch id {
        case 1: values.brightness = Double(p[0]); values.kelvin = Double(p[1]) * 100; values.speed = Double(p[2])
        case 2,3,6,8: values.brightness = Double(p[0]); values.kelvin = Double(p[1]) * 100; tint(2); values.speed = Double(p[3])
        case 4: values.brightness = Double(p[0]); values.kelvin = Double(p[1]) * 100; tint(2); values.speed = Double(p[3]); values.sparks = Double(p[4])
        case 5,15: values.brightness = Double(p[0]); values.brightnessUpper = Double(p[1]); values.kelvin = Double(p[2]) * 100; tint(3); values.speed = Double(p[4])
        case 7,9: values.brightness = Double(p[0]); values.hue = hue(1); values.saturation = Double(p[3]); values.speed = Double(p[4])
        case 10: values.brightness = Double(p[0]); values.colorOption = Int(p[1]); values.speed = Double(p[2])
        case 11: values.brightness = Double(p[0]); values.brightnessUpper = Double(p[1]); values.kelvin = Double(p[2]) * 100; tint(3); values.speed = Double(p[4]); values.sparks = Double(p[5])
        case 12: values.brightness = Double(p[0]); values.hue = hue(1); values.hueUpper = hue(3); values.speed = Double(p[5])
        case 13: values.brightness = Double(p[0]); values.kelvin = Double(p[1]) * 100; values.kelvinUpper = Double(p[2]) * 100; values.speed = Double(p[3])
        case 14: values.colorOption = Int(p[0]); values.brightness = Double(p[1]); values.brightnessUpper = Double(p[2]); values.hue = hue(3); values.kelvin = Double(p[5]) * 100; values.speed = Double(p[6])
        case 16: values.brightness = Double(p[0]); values.colorOption = Int(p[1]); values.speed = Double(p[2]); values.sparks = Double(p[3])
        case 17: values.brightness = Double(p[0]); values.colorOption = Int(p[1]); values.speed = Double(p[2])
        default: break
        }
    }
}

extension RememberedSettings {
    func sanitized(for kind: LightKind) -> RememberedSettings {
        var result = self
        let baseline = RememberedSettings.initial(for: kind)
        func finite(_ value: Double, _ fallback: Double, _ bounds: ClosedRange<Double>) -> Double {
            value.isFinite ? min(bounds.upperBound, max(bounds.lowerBound, value)) : fallback
        }
        result.brightness = finite(brightness, baseline.brightness, 0...100)
        result.brightnessUpper = finite(brightnessUpper, 100, result.brightness...100)
        result.kelvin = finite(kelvin, baseline.kelvin, 2700...6500)
        result.kelvinUpper = finite(kelvinUpper, 6500, result.kelvin...6500)
        result.tint = kind.supportsColor ? finite(tint, 0, -50...50) : 0
        result.hue = finite(hue, baseline.hue, 0...360)
        result.hueUpper = finite(hueUpper, 360, result.hue...360)
        result.saturation = finite(saturation, baseline.saturation, 0...100)
        result.speed = finite(speed, baseline.speed, 1...10)
        result.sparks = finite(sparks, baseline.sparks, 1...10)
        if !kind.supportsColor && result.mode == .color { result.mode = .white }
        if !EffectCatalog.effects(for: kind).contains(where: { $0.id == result.effectID }) { result.effectID = 1 }
        let optionMaximum = kind.supportsColor ? (result.effectID == 10 ? 4 : result.effectID == 14 ? 1 : [16,17].contains(result.effectID) ? 2 : 0) : 0
        result.colorOption = min(optionMaximum, max(0, colorOption))
        return result
    }
}
