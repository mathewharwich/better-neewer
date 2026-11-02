import Foundation

// Every device ID, MAC, and advertising suffix below is a synthetic fixture.
@main enum NeewerProtocolTests {
    static let mac: [UInt8] = [0x02,0x10,0x20,0x30,0x40,0x50]
    static let otherMAC: [UInt8] = [0x02,0x10,0x20,0x30,0x40,0x51]
    static func expect(_ value: Bool, _ message: String, line: Int = #line) {
        guard value else { fatalError("FAIL line \(line): \(message)") }
    }
    static func hex(_ text: String) -> Data { Data(text.split(separator: " ").map { UInt8($0, radix: 16)! }) }
    static func packet(_ command: NeewerCommand, _ kind: LightKind = .cb200b) throws -> Data { try command.packet(for: kind, mac: mac) }
    static func reports(_ data: Data, kind: LightKind = .cb200b, expectedMAC: [UInt8] = mac) -> [NeewerReport] {
        guard let frame = NeewerReplyFrame(Array(data)) else { return [] }
        return NeewerReadback.reports(frame, for: kind, mac: expectedMAC)
    }
    static func rejects(_ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError("Expected rejection: \(message)") } catch {}
    }

    @MainActor static func main() throws {
        let fixtures: [(NeewerCommand,String)] = [
            (.power(true), "78 8D 08 02 10 20 30 40 50 81 01 81"),
            (.power(false), "78 8D 08 02 10 20 30 40 50 81 02 82"),
            (.boost(true), "78 AB 07 02 10 20 30 40 50 01 1D"),
            (.boost(false), "78 AB 07 02 10 20 30 40 50 02 1E"),
            (.query(.state), "78 8E 07 02 10 20 30 40 50 85 84"),
            (.query(.version), "78 9E 06 02 10 20 30 40 50 0E"),
            (.query(.boost), "78 AC 06 02 10 20 30 40 50 1C")]
        for (command, expected) in fixtures { expect(try packet(command) == hex(expected), command.label) }
        for kind in [LightKind.cb60b,.cb60rgb] { rejects("unsupported Boost") { _ = try packet(.boost(true), kind) } }
        for bad in [[],[1,2,3],[UInt8](repeating: 0,count: 6),[UInt8](repeating: 255,count: 6)] {
            rejects("invalid MAC") { _ = try NeewerCommand.power(true).packet(for: .cb200b,mac: bad) }
        }
        print("PASS synthetic wire fixtures, model gates, and address validation")

        var settings = RememberedSettings(brightness: 44)
        expect(try packet(.white(settings,curve: 0)) == hex("78 90 0C 02 10 20 30 40 50 87 2C 2D 32 00 00 18"), "CCT payload fixture")
        settings.brightness = 120; settings.kelvin = -100; settings.tint = 900
        expect(Array(try packet(.white(settings,curve: 3)))[10...14] == [100,27,50,3,0], "bounded CCT and preserved curve")
        settings.brightness = .nan
        rejects("non-finite brightness") { _ = try packet(.white(settings,curve: 0)) }
        settings = RememberedSettings(brightness: 37); settings.hue = 300; settings.saturation = 88
        expect(Array(try packet(.color(settings),.cb60rgb))[9...14] == [0x86,44,1,88,37,0], "HSI LE16 hue")
        rejects("bi-color RGB") { _ = try packet(.color(settings)) }
        settings = RememberedSettings(brightness: 20)
        settings.brightnessUpper = 80; settings.kelvin = 3200; settings.kelvinUpper = 5600
        settings.hue = 300; settings.hueUpper = 360; settings.speed = 8; settings.sparks = 3; settings.colorOption = 2
        for kind in LightKind.allCases {
            for effect in EffectCatalog.effects(for: kind) {
                settings.effectID = effect.id
                let bytes = Array(try packet(.effect(settings),kind))
                expect(bytes[1] == 0x91 && bytes[9] == 0x8B && bytes[10] == UInt8(effect.id), "effect envelope")
                expect(bytes.count <= 20 && bytes.count == Int(bytes[2])+4 && bytes.dropLast().reduce(UInt8(0), &+) == bytes.last, "effect ATT size, length, checksum")
                let parameters = Array(bytes[11..<(bytes.count-1)])
                expect(NeewerEffectCodec.validParameters(parameters,id: effect.id,kind: kind), "effect parameters")
                expect(reports(NeewerWire.frame(0x04,mac+[2,1,3,UInt8(effect.id)]+parameters),kind: kind).count == 2, "effect readback")
            }
        }
        settings.effectID = 14
        expect(Array(try packet(.effect(settings)))[11...17] == [0,20,80,0,0,32,8], "white brightness loop")
        expect(Array(try packet(.effect(settings),.cb60rgb))[11...17] == [1,20,80,44,1,32,8], "color brightness loop")
        for bad in [-1,256,Int.max] { settings.effectID = bad; rejects("invalid effect ID") { _ = try packet(.effect(settings)) } }
        expect(!NeewerEffectCodec.validParameters([90,10,32,50,8],id: 5,kind: .cb200b), "reversed range rejected")
        print("PASS CCT, HSI, all model effects, bounds, invalid IDs and ATT20 size")

        let version = NeewerWire.frame(0x08,mac+[1,10,1,1,5,2]+Array("CB200B".utf8))
        for split in 1..<version.count {
            var decoder = NeewerStreamDecoder()
            expect(decoder.receive(version.prefix(split)).isEmpty, "no partial version")
            let frames = decoder.receive(version.suffix(version.count-split))
            expect(frames.count == 1,"version at every ATT split")
            if case .firmware(let v) = NeewerReadback.reports(frames[0],for: .cb200b,mac: mac).first { expect(v == "1.1.5","version fields") }
            else { fatalError("Missing firmware") }
        }
        let short = NeewerWire.frame(0x04,mac+[2,2])
        expect(reports(short).count == 1,"short state power only")
        expect(reports(short,expectedMAC: otherMAC).isEmpty,"foreign MAC rejected")
        let white = NeewerWire.frame(0x04,mac+[2,1,1,44,45,50,3,0])
        if case .white(let result) = reports(white).last { expect(result.brightness == 44 && result.kelvin == 4500 && result.curve == 3,"white fields") }
        else { fatalError("Missing white readback") }
        let hsi = NeewerWire.frame(0x04,mac+[2,1,2,44,1,88,37,0])
        if case .color(let result) = reports(hsi,kind: .cb60rgb).last { expect(result.hue == 300 && result.saturation == 88 && result.brightness == 37,"HSI fields") }
        else { fatalError("Missing HSI readback") }
        var corrupt = Array(short); corrupt[10] = 1
        expect(NeewerReplyFrame(corrupt) == nil,"checksum rejected")
        var decoder = NeewerStreamDecoder()
        expect(decoder.receive(short+white+version).count == 3,"coalesced replies")
        for code in [UInt8(1),2,99] {
            if case .boost(let enabled,let raw) = reports(NeewerWire.frame(0x11,mac+[code])).first { expect(raw == code && enabled == (code == 1 ? true : code == 2 ? false : nil),"Boost state mapping") }
            else { fatalError("Missing Boost report") }
        }
        print("PASS stream reassembly, checksums, exact MAC, control readback and Boost mapping")

        let name = "NW-20210037&TEST0001"
        func metadata(_ entries: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: ["SPBluetoothDataType": [["device_connected": entries]]]) }
        let selected: [String: Any] = [name:["device_address":"02:10:20:30:40:50"]]
        let unrelated: [String: Any] = ["Unrelated device":["device_address":"02:AA:BB:CC:DD:EE"]]
        expect(NeewerIdentity.resolve(profilerJSON: try metadata([selected,unrelated]),exactName: name) == .found(mac),"exact connected-name match")
        expect(NeewerIdentity.resolve(profilerJSON: try metadata([selected,selected]),exactName: name) == .found(mac),"same address deduplicated")
        expect(NeewerIdentity.resolve(profilerJSON: try metadata([selected,[name:["device_address":"02:10:20:30:40:51"]]]),exactName: name) == .ambiguous,"duplicate names with different addresses")
        expect(NeewerIdentity.resolve(profilerJSON: try metadata([selected,[name:[:]]]),exactName: name) == .ambiguous,"invalid same-name entry blocks resolution")
        expect(NeewerIdentity.resolve(profilerJSON: try metadata([unrelated]),exactName: name) == .missing,"unrelated metadata ignored")
        expect(NeewerIdentity.resolve(profilerJSON: Data("invalid".utf8),exactName: name) == .missing,"invalid JSON")
        expect(NeewerIdentity.parseMAC("02:10:20:30:40:50") == mac && NeewerIdentity.parseMAC("02:10:20") == nil,"manual address syntax")
        print("PASS conservative address resolution, ambiguous metadata, and manual address entry")

        let one = UUID(uuidString:"00000000-0000-4000-8000-000000000001")!
        let two = UUID(uuidString:"00000000-0000-4000-8000-000000000002")!
        let first = LightState(id: one,kind: .cb200b,advertisedName: name,mac: mac)
        let second = LightState(id: two,kind: .cb200b,advertisedName: name,mac: otherMAC)
        expect(first.id != second.id && first.kind == second.kind,"multiple instances of one model")
        expect(first.accepts(identifier: one,name: name) && !first.accepts(identifier: two,name: name),"exact instance identity")
        first.connection = .connected
        expect(!first.canControl,"metadata alone never permits setting writes")
        first.identityConfirmed = true
        expect(first.canControl && first.valuesLabel == "Default values","verified identity and truthful defaults")
        expect(LightKind.detect(name: name) == .cb200b && LightKind.detect(name:"NW-202100370&OTHER") == nil,"strict model prefix")
        var unsafe = RememberedSettings(); unsafe.brightness = .infinity; unsafe.brightnessUpper = -10; unsafe.kelvin = 99999; unsafe.kelvinUpper = 1; unsafe.mode = .color; unsafe.effectID = -1
        let clean = unsafe.sanitized(for: .cb200b)
        expect(clean.brightness == 50 && clean.brightnessUpper >= clean.brightness && clean.kelvinUpper >= clean.kelvin && clean.mode == .white && clean.effectID == 1,"generic persisted settings sanitation")
        print("PASS dynamic device identities, repeated models, readback gating, and settings sanitation")
        print("ALL PUBLIC CORE TESTS PASSED — offline; no hardware used")
    }
}
