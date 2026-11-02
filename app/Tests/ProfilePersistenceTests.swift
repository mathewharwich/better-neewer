import Foundation

@main enum ProfilePersistenceTests {
    @MainActor static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BetterNeewer-ProfileTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("profiles-v2.json")
        let privateFile = folder.appendingPathComponent("studio.json")
        let privateSentinel = Data("private legacy file remains unchanged".utf8)
        try privateSentinel.write(to: privateFile)
        func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }
        let empty = StudioController(storageURL: file)
        expect(empty.lights.isEmpty, "Fresh install must have no preconfigured devices")
        expect(!FileManager.default.fileExists(atPath: file.path), "Initialization must not create a store")
        empty.shutdown()

        let settings = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RememberedSettings(brightness: 36)))
        let one = "00000000-0000-4000-8000-000000000001"
        let two = "00000000-0000-4000-8000-000000000002"
        let oneID = UUID(uuidString: one)!, twoID = UUID(uuidString: two)!
        // A fixture held connected by another app may not advertise. Inventory
        // names must become candidates without requiring advertisement metadata.
        let inventory = EnrollmentCandidates.make(id: oneID, peripheralName: "NW-20210037&TEST0001", savedIDs: [])!
        expect(inventory.kind == .cb200b && inventory.rssi == nil, "Connected inventory creates an enrollment candidate")
        // These advertisements intentionally contain no service UUID list.
        let advertisement = EnrollmentCandidates.make(id: twoID, peripheralName: nil, advertisedName: "NW-20210037&TEST0002", rssi: -42, savedIDs: [])!
        expect(EnrollmentCandidates.canEnroll(advertisement, peripheralID: twoID, peripheralName: nil, observedName: advertisement.advertisedName), "A vetted ad-only candidate remains enrollable when CoreBluetooth name is nil")
        expect(!EnrollmentCandidates.canEnroll(advertisement, peripheralID: oneID, peripheralName: nil, observedName: advertisement.advertisedName), "Advertising name never substitutes for exact UUID")
        expect(!EnrollmentCandidates.canEnroll(advertisement, peripheralID: twoID, peripheralName: nil, observedName: nil), "Missing observation cannot authenticate an ad-only candidate")
        expect(!EnrollmentCandidates.canEnroll(advertisement, peripheralID: twoID, peripheralName: "NW-20210037&DIFFERENT", observedName: advertisement.advertisedName), "A conflicting full peripheral name rejects enrollment")
        expect(EnrollmentCandidates.make(id: twoID, peripheralName: "NW-20210037&DIFFERENT", advertisedName: advertisement.advertisedName, savedIDs: []) == nil, "Conflicting native and advertising names are never offered")
        let adOnlyProfile = LightState(id: twoID, kind: advertisement.kind, advertisedName: advertisement.advertisedName, mac: [2,16,32,48,64,80])
        let carriedName = EnrollmentCandidates.identityName(peripheralName: nil, observedName: advertisement.advertisedName)
        expect(adOnlyProfile.accepts(identifier: twoID, name: carriedName), "The same vetted observation supports connection and callback identity matching")
        adOnlyProfile.connection = .connected
        expect(!adOnlyProfile.canControl, "Ad-only enrollment still requires separate live MAC readback before setters")
        var candidates: [DiscoveredLight] = []
        EnrollmentCandidates.upsert(inventory, into: &candidates)
        EnrollmentCandidates.upsert(advertisement, into: &candidates)
        expect(candidates.count == 2, "Inventory and advertisement can expose two units of one model")
        let updated = EnrollmentCandidates.make(id: oneID, peripheralName: inventory.advertisedName, rssi: -55, savedIDs: [])!
        EnrollmentCandidates.upsert(updated, into: &candidates)
        EnrollmentCandidates.upsert(inventory, into: &candidates)
        expect(candidates.count == 2 && candidates.first?.rssi == -55, "Upsert deduplicates IDs and preserves RSSI across inventory snapshots")
        expect(EnrollmentCandidates.make(id: oneID, peripheralName: inventory.advertisedName, savedIDs: [oneID]) == nil, "Saved instances are excluded from enrollment")
        expect(EnrollmentCandidates.make(id: oneID, peripheralName: "Unrelated device", advertisedName: "Also unrelated", savedIDs: []) == nil, "Unrelated names are excluded")
        expect(EnrollmentCandidates.make(id: oneID, peripheralName: "NW-202100370&TEST", savedIDs: []) == nil, "Model-prefix near matches are rejected")
        print("PASS enrollment: connected inventory, advertisements without service UUIDs, same-model instances, upsert, and saved-device exclusion")
        func record(_ id: String, _ suffix: String, _ name: String) -> [String: Any] {
            ["id": id, "kind": "cb200b", "advertisedName": "NW-20210037&" + suffix,
             "mac": [2,16,32,48,64,80], "name": name, "settings": settings, "hasSavedSettings": true]
        }
        let document: [String: Any] = ["version": 2,"lights": [one: record(one,"TEST0001","Fixture one"), two: record(two,"TEST0002","Fixture two")]]
        try JSONSerialization.data(withJSONObject: document).write(to: file)
        let restored = StudioController(storageURL: file)
        expect(restored.lights.count == 2 && Set(restored.lights.map(\.id)).count == 2, "Multiple instances of the same model must restore")
        expect(restored.lights.allSatisfy { $0.kind == .cb200b && $0.settings.brightness == 36 && $0.valuesLabel == "Remembered values" }, "Restore only intended settings")
        expect(restored.lights.allSatisfy { !$0.canControl && !$0.identityConfirmed }, "Saved MAC must not bypass live identity verification")
        let removed = restored.lights[0]
        restored.remove(removed)
        expect(restored.lights.count == 1, "Remove only selected profile")
        let retained = restored.lights[0]
        retained.displayName = " Renamed fixture "
        restored.saveName(retained)
        retained.settings.brightness = 42
        restored.saveSettings(retained)
        restored.shutdown() // flush debounced intended settings, no manager exists
        let reloaded = StudioController(storageURL: file)
        expect(reloaded.lights.count == 1 && reloaded.lights[0].displayName == "Renamed fixture" && reloaded.lights[0].settings.brightness == 42, "Rename/removal/settings survive reload")
        expect(try Data(contentsOf: privateFile) == privateSentinel, "Legacy private file must remain byte-for-byte unchanged")
        reloaded.shutdown()
        let broken = Data("not JSON".utf8)
        try broken.write(to: file)
        let corrupt = StudioController(storageURL: file)
        let preserved = try Data(contentsOf: file)
        expect(corrupt.lights.isEmpty && preserved == broken, "Malformed store fails closed without overwriting source")
        corrupt.shutdown()
        print("PASS public profile persistence: zero/multiple same-model instances, rename/remove, debounced flush, malformed data, and legacy-file preservation")
        print("NO BLUETOOTH MANAGER CREATED — no hardware or installed application data used")
    }
}
