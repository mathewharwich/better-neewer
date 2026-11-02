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
