import Foundation
import Combine
@preconcurrency import CoreBluetooth

@MainActor
final class StudioController: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published private(set) var lights: [LightState]
    @Published private(set) var availableLights: [DiscoveredLight] = []
    @Published var enrollmentStatus = "Add a supported light to get started."
    @Published var bluetoothStatus = "Bluetooth has not started"
    @Published var isScanning = false

    private let serviceID = CBUUID(string: "69400001-B5A3-F393-E0A9-E50E24DCCA99")
    private let commandID = CBUUID(string: "69400002-B5A3-F393-E0A9-E50E24DCCA99")
    private let notifyID = CBUUID(string: "69400003-B5A3-F393-E0A9-E50E24DCCA99")
    private var central: CBCentralManager?
    private var scanTimer: Timer?
    private var scanWhenReady = false
    private var connectWhenReady = false
    private var stopped = false
    private var sessions: [UUID: Session] = [:]
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var observedNames: [UUID: String] = [:]
    private let storeURL: URL
    private var persistenceTimer: Timer?

    private struct SavedLight: Codable {
        var id: UUID
        var kind: LightKind
        var advertisedName: String
        var mac: [UInt8]?
        var name: String
        var settings: RememberedSettings
        var hasSavedSettings: Bool
    }
    private struct SavedStudio: Codable { var version = 2; var lights: [String: SavedLight] }
    private var saved: SavedStudio

    private struct Outbound {
        let id = UUID()
        let command: NeewerCommand
        let data: Data
        let requestToken: UUID?
    }
    @MainActor private final class Session {
        let light: LightState
        var peripheral: CBPeripheral?
        var characteristic: CBCharacteristic?
        var notifyReady = false
        var queue: [Outbound] = []
        var inFlight: Outbound?
        var pendingValue: NeewerCommand?
        var decoder = NeewerStreamDecoder()
        var reportedCurve: UInt8?
        var wantsConnection = false
        var retryRemaining = 0
        var lastEdit = Date.distantPast
        var powerRequestToken: UUID?
        var boostRequestToken: UUID?
        var connectTimer: Timer?
        var retryTimer: Timer?
        var writeTimer: Timer?
        var pumpTimer: Timer?
        var coalesceTimer: Timer?
        var verificationTimers: [Timer] = []
        var addressResolutionTask: Task<Void, Never>?
        init(_ light: LightState) { self.light = light }
        func cancelWork() {
            [connectTimer, retryTimer, writeTimer, pumpTimer, coalesceTimer].forEach { $0?.invalidate() }
            verificationTimers.forEach { $0.invalidate() }
            verificationTimers = []
            addressResolutionTask?.cancel(); addressResolutionTask = nil
            connectTimer = nil; retryTimer = nil; writeTimer = nil; pumpTimer = nil; coalesceTimer = nil
            queue = []; inFlight = nil; pendingValue = nil
            characteristic = nil; notifyReady = false; decoder = NeewerStreamDecoder()
            light.isSending = false; light.requestedPower = nil; light.requestedBoost = nil
            powerRequestToken = nil; boostRequestToken = nil
        }
    }

    init(storageURL: URL? = nil) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Better Neewer", isDirectory: true)
        // Separate public schema; never overwrite older private studio.json data.
        storeURL = storageURL ?? folder.appendingPathComponent("profiles-v2.json")
        let loaded: SavedStudio
        if let data = try? Data(contentsOf: storeURL), let state = try? JSONDecoder().decode(SavedStudio.self, from: data), state.version == 2 {
            loaded = state
        } else { loaded = SavedStudio(lights: [:]) }
        saved = loaded
        var seen = Set<UUID>()
        lights = loaded.lights.values.sorted { $0.name < $1.name }.compactMap { record in
            guard LightKind.detect(name: record.advertisedName) == record.kind, seen.insert(record.id).inserted else { return nil }
            let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return LightState(id: record.id, kind: record.kind, advertisedName: record.advertisedName, mac: record.mac,
                              settings: record.hasSavedSettings ? record.settings.sanitized(for: record.kind) : nil,
                              name: name.isEmpty ? nil : String(name.prefix(64)))
        }
        super.init()
        for light in lights { sessions[light.id] = Session(light) }
        if !lights.isEmpty { enrollmentStatus = "Your saved lights are ready to connect." }
    }

    func scan() {
        enrollmentStatus = "Looking for CB200B, CB60B, and CB60 RGB lights…"
        availableLights = []
        observedNames = [:]
        discoveredPeripherals = [:]
        if central == nil { start() }
        else if central?.state == .poweredOn { scanKnown() }
        else { scanWhenReady = true; enrollmentStatus = "Bluetooth must be available before scanning." }
    }

    func addLight(_ candidate: DiscoveredLight, macAddress: String? = nil) {
        guard sessions[candidate.id] == nil,
              let peripheral = discoveredPeripherals[candidate.id],
              peripheral.name == candidate.advertisedName,
              LightKind.detect(name: candidate.advertisedName) == candidate.kind else {
            enrollmentStatus = "This discovery is no longer available. Scan again."; return
        }
        let manual = macAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mac: [UInt8]?
        if !manual.isEmpty {
            guard let parsed = NeewerIdentity.parseMAC(manual) else {
                enrollmentStatus = "Enter six hexadecimal address pairs separated by colons, or leave the address empty."; return
            }
            mac = parsed
        } else { mac = nil }
        let light = LightState(id: candidate.id, kind: candidate.kind, advertisedName: candidate.advertisedName, mac: mac)
        let session = Session(light); session.peripheral = peripheral
        sessions[light.id] = session
        lights.append(light)
        saved.lights[light.id.uuidString] = profile(for: light)
        persist(for: light)
        availableLights.removeAll { $0.id == candidate.id }
        enrollmentStatus = "Added \(light.kind.name). Connecting to verify its address…"
        connect(light)
    }

    func remove(_ light: LightState) {
        guard sessions[light.id]?.light === light else { return }
        disconnect(light)
        let previous = saved.lights.removeValue(forKey: light.id.uuidString)
        do {
            try writeStore()
            sessions.removeValue(forKey: light.id)
            lights.removeAll { $0.id == light.id }
            enrollmentStatus = "Removed the local profile. The light's settings were not changed."
        } catch {
            saved.lights[light.id.uuidString] = previous
            light.error = "Could not remove the saved profile: \(error.localizedDescription)"
        }
    }

    private func profile(for light: LightState) -> SavedLight {
        SavedLight(id: light.id, kind: light.kind, advertisedName: light.advertisedName, mac: light.mac,
                   name: light.displayName, settings: light.settings, hasSavedSettings: light.hasRememberedSettings)
    }

    private func resolveAddress(for session: Session) {
        session.addressResolutionTask?.cancel()
        let rawName = session.light.advertisedName
        guard !hasDuplicateName(rawName) else { addressUnavailable(session, ambiguous: true); return }
        session.light.message = "Resolving this light's address from local macOS Bluetooth metadata…"
        session.addressResolutionTask = Task { @MainActor [weak self, weak session] in
            // Metadata may appear shortly after CoreBluetooth connects. Two bounded
            // attempts are enough; unresolved identity never enables control writes.
            for attempt in 0..<2 {
                let result = await Task.detached(priority: .utility) {
                    Self.readConnectedAddress(exactName: rawName)
                }.value
                guard !Task.isCancelled, let self, let session,
                      session.light.connection == .connected, self.sessions[session.light.id] === session else { return }
                guard !self.hasDuplicateName(rawName) else { self.addressUnavailable(session, ambiguous: true); return }
                switch result {
                case .found(let mac):
                    session.light.mac = mac
                    var record = self.saved.lights[session.light.id.uuidString] ?? self.profile(for: session.light)
                    record.mac = mac
                    self.saved.lights[session.light.id.uuidString] = record
                    self.persist(for: session.light)
                    session.light.message = "Address resolved. Verifying read-only status…"
                    self.refresh(session.light)
                    return
                case .ambiguous: self.addressUnavailable(session, ambiguous: true); return
                case .missing:
                    if attempt == 0 { try? await Task.sleep(for: .seconds(1)) }
                    else { self.addressUnavailable(session, ambiguous: false) }
                }
            }
        }
    }

    private func hasDuplicateName(_ name: String) -> Bool {
        if let central {
            for peripheral in central.retrieveConnectedPeripherals(withServices: [serviceID]) {
                if let raw = peripheral.name, LightKind.detect(name: raw) != nil { observedNames[peripheral.identifier] = raw }
            }
        }
        return observedNames.values.filter { $0 == name }.count > 1
    }

    private func addressUnavailable(_ session: Session, ambiguous: Bool) {
        session.light.identityConfirmed = false
        session.light.error = ambiguous
            ? "More than one light has this Bluetooth name. Disconnect or power down the others while adding, or remove this profile and add it with a known MAC address."
            : "macOS has not reported this light's address. Try reconnecting, or remove this profile and add it with a known MAC address."
        enrollmentStatus = session.light.error ?? "Address not resolved."
    }

    nonisolated private static func readConnectedAddress(exactName: String) -> NeewerIdentity.Resolution {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-timeout", "8"]
        process.qualityOfService = .utility
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return .missing }
            return NeewerIdentity.resolve(profilerJSON: data, exactName: exactName)
        } catch { return .missing }
    }

    func start() {
        guard central == nil else { if central?.state == .poweredOn { scanKnown() }; return }
        stopped = false
        scanWhenReady = true
        bluetoothStatus = "Starting Bluetooth…"
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    func connectAll() {
        stopped = false
        if central == nil { connectWhenReady = true; start(); return }
        guard central?.state == .poweredOn else {
            connectWhenReady = true
            for light in lights { light.error = "Bluetooth must be available before connecting." }
            return
        }
        scanKnown()
        for light in lights { connect(light) }
    }

    func connect(_ light: LightState) {
        guard let session = sessions[light.id], session.light === light else { return }
        light.error = nil
        light.message = nil
        if central == nil { start() }
        guard let central, central.state == .poweredOn else {
            light.error = "Bluetooth is not ready. Try Connect again when it is available."; return
        }
        guard light.connection == .disconnected else { return }
        session.wantsConnection = true
        session.retryRemaining = 1
        session.retryTimer?.invalidate()
        beginConnect(session)
    }

    private func beginConnect(_ session: Session) {
        guard !stopped, session.wantsConnection, let central, central.state == .poweredOn else { return }
        let light = session.light
        if session.peripheral == nil {
            session.peripheral = central.retrievePeripherals(withIdentifiers: [light.id]).first
        }
        guard let peripheral = session.peripheral,
              light.accepts(identifier: peripheral.identifier, name: peripheral.name) else {
            light.error = "Your \(light.kind.name) has not been found. Turn on its mains power, then try again."
            light.connection = .disconnected
            scanKnown()
            return
        }
        session.cancelWork()
        light.identityConfirmed = false
        light.reportedPower = nil; light.reportedBoost = nil; light.firmware = nil
        light.valuesLabel = light.hasRememberedSettings ? "Remembered values" : "Default values"
        light.connection = .connecting
        peripheral.delegate = self
        central.connect(peripheral)
        session.connectTimer = later(10) { [weak self, weak session] in
            guard let self, let session, session.light.connection != .connected else { return }
            session.light.error = "Connection timed out. Check that the light is nearby and powered."
            self.central?.cancelPeripheralConnection(peripheral)
            self.connectionEnded(session, retry: true)
        }
    }

    func disconnect(_ light: LightState) {
        guard let session = sessions[light.id], session.light === light else { return }
        session.wantsConnection = false
        session.retryRemaining = 0
        session.cancelWork()
        light.connection = .disconnected
        light.identityConfirmed = false
        light.message = "Disconnected. The light keeps its current settings."
        if let peripheral = session.peripheral { central?.cancelPeripheralConnection(peripheral) }
    }

    func refresh(_ light: LightState) {
        if let session = sessions[light.id], session.light === light, light.connection == .connected,
           !NeewerIdentity.isValidMAC(light.mac) {
            light.error = nil
            resolveAddress(for: session)
            return
        }
        guard let session = readySession(light, allowUnconfirmed: true) else { return }
        light.error = nil
        light.message = "Reading light…"
        enqueue(.query(.version), in: session)
        enqueue(.query(.state), in: session)
        if light.kind.supportsBoost { enqueue(.query(.boost), in: session) }
        if !light.identityConfirmed {
            session.verificationTimers.append(later(3) { [weak session] in
                guard let session, session.light.connection == .connected, !session.light.identityConfirmed else { return }
                session.light.error = "The light has not confirmed this address. Check the MAC address or refresh its status."
            })
        }
    }

    func setPower(_ light: LightState, on: Bool) {
        guard let session = readySession(light) else { return }
        light.error = nil
        light.requestedPower = on
        session.powerRequestToken = UUID()
        light.message = "Requesting power \(on ? "on" : "off")…"
        if !on { session.pendingValue = nil; session.coalesceTimer?.invalidate(); session.coalesceTimer = nil; session.queue.removeAll { $0.command.isValueSetting } }
        enqueue(.power(on), in: session)
    }

    func setBoost(_ light: LightState, enabled: Bool) {
        guard let session = readySession(light) else { return }
        guard light.canBoost else { light.error = "Boost is verified for your CB200B on firmware 1.1.5. Refresh its status first."; return }
        light.error = nil
        light.requestedBoost = enabled
        session.boostRequestToken = UUID()
        light.message = "Requesting Boost \(enabled ? "enabled" : "disabled")…"
        enqueue(.boost(enabled), in: session)
    }

    func applyWhite(_ light: LightState) {
        light.settings.mode = .white
        saveSettings(light)
        guard let session = readySession(light) else { return }
        coalesce(.white(light.settings, curve: session.reportedCurve ?? 0), in: session)
    }

    func applyColor(_ light: LightState) {
        light.settings.mode = .color
        saveSettings(light)
        guard let session = readySession(light) else { return }
        coalesce(.color(light.settings), in: session)
    }

    func applyEffect(_ light: LightState) {
        light.settings.mode = .effects
        saveSettings(light)
        guard let session = readySession(light) else { return }
        coalesce(.effect(light.settings), in: session)
    }

    func saveName(_ light: LightState) {
        guard sessions[light.id]?.light === light else { return }
        light.error = nil
        let name = light.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        light.displayName = name.isEmpty ? light.kind.name : String(name.prefix(64))
        var record = saved.lights[light.id.uuidString] ?? profile(for: light)
        record.name = light.displayName
        saved.lights[light.id.uuidString] = record
        persist(for: light)
    }

    func saveSettings(_ light: LightState) {
        guard sessions[light.id]?.light === light else { return }
        light.error = nil
        light.settings = light.settings.sanitized(for: light.kind)
        light.hasRememberedSettings = true
        saved.lights[light.id.uuidString] = profile(for: light)
        persistenceTimer?.invalidate()
        persistenceTimer = later(0.3) { [weak self, weak light] in
            guard let self, let light else { return }
            self.persistenceTimer = nil
            self.persist(for: light)
        }
    }

    private func persist(for light: LightState) {
        do { try writeStore() } catch { light.error = "Could not remember settings: \(error.localizedDescription)" }
    }

    private func writeStore() throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(saved).write(to: storeURL, options: .atomic)
    }

    func shutdown() {
        if persistenceTimer != nil { persistenceTimer?.invalidate(); persistenceTimer = nil; if let light = lights.first { persist(for: light) } }
        stopped = true
        scanWhenReady = false; connectWhenReady = false
        scanTimer?.invalidate(); central?.stopScan(); isScanning = false
        for session in sessions.values {
            session.wantsConnection = false; session.retryRemaining = 0; session.cancelWork()
            session.light.connection = .disconnected
            if let peripheral = session.peripheral { central?.cancelPeripheralConnection(peripheral) }
        }
    }

    // Called on a real system wake or Bluetooth power restoration. It resumes
    // only the user's existing connection intent, with one bounded attempt per
    // external event. A manually disconnected light remains disconnected.
    func resumeWantedConnections() {
        guard !stopped, central?.state == .poweredOn else { return }
        scanKnown()
        for session in sessions.values where session.wantsConnection && session.light.connection == .disconnected {
            session.retryTimer?.invalidate(); session.retryTimer = nil
            session.retryRemaining = 0
            session.light.error = nil
            session.light.message = "Reconnecting after wake…"
            beginConnect(session)
        }
    }

    private func readySession(_ light: LightState, allowUnconfirmed: Bool = false) -> Session? {
        guard let session = sessions[light.id], session.light === light,
              (allowUnconfirmed ? light.connection == .connected && NeewerIdentity.isValidMAC(light.mac) : light.canControl),
              session.notifyReady, session.characteristic != nil, session.peripheral?.state == .connected else {
            light.error = "Connect this light before changing its controls."; return nil
        }
        return session
    }

    private func coalesce(_ command: NeewerCommand, in session: Session) {
        session.light.error = nil
        session.lastEdit = Date()
        session.light.valuesLabel = "Sending values…"
        session.pendingValue = command
        guard session.coalesceTimer == nil else { return }
        session.coalesceTimer = later(0.08) { [weak self, weak session] in
            guard let self, let session else { return }
            session.coalesceTimer = nil
            guard let latest = session.pendingValue else { return }
            session.pendingValue = nil
            self.enqueue(latest, in: session)
        }
    }

    private func enqueue(_ command: NeewerCommand, in session: Session) {
        guard session.light.connection == .connected, session.notifyReady,
              let peripheral = session.peripheral,
              session.light.accepts(identifier: peripheral.identifier, name: peripheral.name), let mac = session.light.mac else { return }
        do {
            if case .query = command {} else if !session.light.identityConfirmed { return }
            let packet = try command.packet(for: session.light.kind, mac: mac)
            if command.isValueSetting { session.queue.removeAll { $0.command.isValueSetting } }
            if case .query(let query) = command,
               session.queue.contains(where: { if case .query(let candidate) = $0.command { return query == candidate }; return false }) { return }
            let token: UUID?
            switch command { case .power: token = session.powerRequestToken; case .boost: token = session.boostRequestToken; default: token = nil }
            session.queue.append(Outbound(command: command, data: packet, requestToken: token))
            pump(session)
        } catch {
            session.light.error = error.localizedDescription
            session.light.isSending = false
            if command.isValueSetting { session.light.valuesLabel = "Remembered values" }
        }
    }

    private func pump(_ session: Session) {
        guard session.inFlight == nil, session.pumpTimer == nil,
              session.light.connection == .connected, session.notifyReady,
              let peripheral = session.peripheral, peripheral.state == .connected,
              let characteristic = session.characteristic, !session.queue.isEmpty,
              session.light.accepts(identifier: peripheral.identifier, name: peripheral.name) else { return }
        let type: CBCharacteristicWriteType
        if characteristic.properties.contains(.write) { type = .withResponse }
        else if characteristic.properties.contains(.writeWithoutResponse) {
            guard peripheral.canSendWriteWithoutResponse else { return }
            type = .withoutResponse
        } else { failTransport(session, "The light has no supported command characteristic."); return }
        let item = session.queue.removeFirst()
        guard item.data.count <= peripheral.maximumWriteValueLength(for: type) else {
            failTransport(session, "The light's Bluetooth packet limit is too small for this command."); return
        }
        session.light.isSending = true
        if type == .withResponse {
            session.inFlight = item
            session.writeTimer = later(3) { [weak self, weak session] in
                guard let self, let session, session.inFlight?.id == item.id else { return }
                self.failTransport(session, "The light did not acknowledge a Bluetooth write. Reconnect to retry.")
            }
        }
        peripheral.writeValue(item.data, for: characteristic, type: type)
        if type == .withoutResponse { delivered(item, in: session) }
    }

    private func delivered(_ item: Outbound, in session: Session) {
        if let query = item.command.verification {
            session.verificationTimers.removeAll { !$0.isValid }
            // Let a finished slider edit settle before merging an extended
            // settings reply; power and Boost remain quick single actions.
            let verificationDelay = item.command.isValueSetting ? 0.65 : 0.3
            session.verificationTimers.append(later(verificationDelay) { [weak self, weak session] in
                guard let self, let session else { return }
                self.enqueue(.query(query), in: session)
            })
            if item.command.isValueSetting {
                let newerValuesPending = session.pendingValue != nil || session.queue.contains { $0.command.isValueSetting }
                session.light.valuesLabel = newerValuesPending ? "Sending values…" : "Last sent values"
                session.light.message = "Controls sent. Waiting for reported values."
            }
        }
        if let token = item.requestToken {
            session.verificationTimers.append(later(2.5) { [weak session] in
                guard let session else { return }
                switch item.command {
                case .power where session.powerRequestToken == token && session.light.requestedPower != nil:
                    session.powerRequestToken = nil; session.light.requestedPower = nil
                    session.light.error = "No reported power confirmation. Refresh the light's status."
                case .boost where session.boostRequestToken == token && session.light.requestedBoost != nil:
                    session.boostRequestToken = nil; session.light.requestedBoost = nil
                    session.light.error = "No reported Boost confirmation. Refresh the light's status."
                default: break
                }
            })
        }
        session.light.isSending = !session.queue.isEmpty
        session.pumpTimer = later(0.08) { [weak self, weak session] in
            guard let self, let session else { return }
            session.pumpTimer = nil
            self.pump(session)
        }
    }

    private func failTransport(_ session: Session, _ message: String) {
        session.light.error = message
        session.wantsConnection = false; session.retryRemaining = 0
        session.cancelWork()
        session.light.connection = .disconnected
        if let peripheral = session.peripheral { central?.cancelPeripheralConnection(peripheral) }
    }

    private func connectionEnded(_ session: Session, retry: Bool) {
        session.cancelWork()
        session.light.connection = .disconnected
        guard retry, !stopped, session.wantsConnection, session.retryRemaining > 0, central?.state == .poweredOn else { return }
        session.retryRemaining -= 1
        session.light.message = "Trying the connection once more…"
        session.retryTimer = later(2) { [weak self, weak session] in
            guard let self, let session else { return }
            session.light.error = nil
            self.beginConnect(session)
        }
    }

    private func later(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Timer {
        Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            Task { @MainActor in action() }
        }
    }

    private func scanKnown() {
        guard !stopped, let central, central.state == .poweredOn else { return }
        scanTimer?.invalidate(); central.stopScan()
        for light in lights {
            if let peripheral = central.retrievePeripherals(withIdentifiers: [light.id]).first,
               light.accepts(identifier: peripheral.identifier, name: peripheral.name) {
                sessions[light.id]?.peripheral = peripheral
            }
        }
        for peripheral in central.retrieveConnectedPeripherals(withServices: [serviceID]) {
            if let name = peripheral.name, LightKind.detect(name: name) != nil { observedNames[peripheral.identifier] = name }
        }
        central.scanForPeripherals(withServices: [serviceID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
        scanTimer = later(8) { [weak self] in self?.central?.stopScan(); self?.isScanning = false }
    }

    private func session(for peripheral: CBPeripheral) -> Session? {
        guard let session = sessions[peripheral.identifier], session.light.accepts(identifier: peripheral.identifier, name: peripheral.name) else { return nil }
        return session
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothStatus = "Mac Bluetooth ready"
            if scanWhenReady { scanWhenReady = false; scanKnown() }
            if connectWhenReady { connectWhenReady = false; connectAll() }
            else { resumeWantedConnections() }
        case .poweredOff: bluetoothStatus = "Bluetooth is off"
        case .unauthorized: bluetoothStatus = "Allow Bluetooth in System Settings → Privacy & Security"
        case .unsupported: bluetoothStatus = "Bluetooth LE is unavailable on this Mac"
        case .resetting: bluetoothStatus = "Bluetooth is restarting…"
        case .unknown: bluetoothStatus = "Checking Bluetooth…"
        @unknown default: bluetoothStatus = "Bluetooth is unavailable"
        }
        if central.state != .poweredOn {
            scanTimer?.invalidate(); isScanning = false
            for session in sessions.values {
                session.cancelWork(); session.light.connection = .disconnected
                session.light.message = bluetoothStatus
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name, let kind = LightKind.detect(name: name) else { return }
        observedNames[peripheral.identifier] = name
        discoveredPeripherals[peripheral.identifier] = peripheral
        if let session = session(for: peripheral) {
            session.peripheral = peripheral
            session.light.hasBeenSeen = true
            if session.wantsConnection && session.light.connection == .disconnected && session.retryTimer == nil { beginConnect(session) }
        } else {
            let candidate = DiscoveredLight(id: peripheral.identifier, kind: kind, advertisedName: name, rssi: RSSI.intValue, mac: nil)
            if let index = availableLights.firstIndex(where: { $0.id == candidate.id }) { availableLights[index] = candidate }
            else { availableLights.append(candidate) }
            enrollmentStatus = "Found \(availableLights.count) supported light\(availableLights.count == 1 ? "" : "s"). Choose one to add."
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let session = session(for: peripheral), session.wantsConnection, !stopped else {
            central.cancelPeripheralConnection(peripheral); return
        }
        session.light.hasBeenSeen = true
        session.light.connection = .discovering
        peripheral.delegate = self
        peripheral.discoverServices([serviceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let session = session(for: peripheral) else { return }
        guard session.light.connection != .disconnected else { return }
        session.light.error = error?.localizedDescription ?? "Could not connect to the light."
        connectionEnded(session, retry: true)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let session = session(for: peripheral) else { return }
        guard session.light.connection != .disconnected else { return } // timeout/manual disconnect already handled
        if let error { session.light.error = "Connection lost: \(error.localizedDescription)" }
        connectionEnded(session, retry: error != nil || session.wantsConnection)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let session = session(for: peripheral) else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
            failTransport(session, error?.localizedDescription ?? "The expected Neewer service was not found."); return
        }
        peripheral.discoverCharacteristics([commandID, notifyID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let session = session(for: peripheral), service.uuid == serviceID else { return }
        guard error == nil,
              let command = service.characteristics?.first(where: { $0.uuid == commandID }),
              let notify = service.characteristics?.first(where: { $0.uuid == notifyID }),
              command.properties.contains(.write) || command.properties.contains(.writeWithoutResponse),
              notify.properties.contains(.notify) || notify.properties.contains(.indicate) else {
            failTransport(session, error?.localizedDescription ?? "The expected Neewer Bluetooth controls were not found."); return
        }
        session.characteristic = command
        peripheral.setNotifyValue(true, for: notify)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == notifyID, let session = session(for: peripheral) else { return }
        guard error == nil, characteristic.isNotifying else {
            failTransport(session, error?.localizedDescription ?? "The light would not enable Bluetooth status replies."); return
        }
        session.notifyReady = true
        session.connectTimer?.invalidate()
        session.light.connection = .connected
        session.light.error = nil
        session.light.message = "Connected directly to this Mac"
        if NeewerIdentity.isValidMAC(session.light.mac) { refresh(session.light) }
        else { resolveAddress(for: session) }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == commandID, let session = session(for: peripheral), let item = session.inFlight else { return }
        session.writeTimer?.invalidate(); session.writeTimer = nil; session.inFlight = nil
        if let error { failTransport(session, "Bluetooth write failed: \(error.localizedDescription)"); return }
        delivered(item, in: session) // transport ACK is not reported hardware state
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let session = session(for: peripheral) else { return }
        pump(session)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == notifyID, let session = session(for: peripheral), session.notifyReady else { return }
        if let error { session.light.error = "Status read failed: \(error.localizedDescription)"; return }
        guard let data = characteristic.value else { return }
        guard let mac = session.light.mac else { return }
        for frame in session.decoder.receive(data) {
            let reports = NeewerReadback.reports(frame, for: session.light.kind, mac: mac)
            if !reports.isEmpty { session.light.identityConfirmed = true }
            for report in reports { apply(report, to: session) }
        }
    }

    private func apply(_ report: NeewerReport, to session: Session) {
        let light = session.light
        switch report {
        case .firmware(let version): light.firmware = version
        case .power(let power):
            light.reportedPower = power
            if let requested = light.requestedPower {
                light.message = power == requested ? "Light reports power \(requested ? "on" : "off")" : "Power reply differs from the requested state."
                light.requestedPower = nil
                session.powerRequestToken = nil
            } else if light.requestedBoost == nil { light.message = "Status received from the light" }
        case .boost(let enabled, let raw):
            light.reportedBoost = enabled
            if let requested = light.requestedBoost {
                light.message = enabled == requested ? "Light reports Boost \(requested ? "enabled" : "disabled")" : "Boost reply differs from the requested state (raw \(raw))."
                light.requestedBoost = nil
                session.boostRequestToken = nil
            }
        case .white(let values):
            session.reportedCurve = values.curve
            guard canMergeReportedValues(session) else { return }
            light.settings.mode = .white
            light.settings.brightness = values.brightness; light.settings.kelvin = values.kelvin
            if light.kind.supportsColor { light.settings.tint = values.tint }
            light.valuesLabel = "Reported by light"
        case .color(let values):
            guard canMergeReportedValues(session) else { return }
            light.settings.mode = .color
            light.settings.brightness = values.brightness; light.settings.hue = values.hue; light.settings.saturation = values.saturation
            light.valuesLabel = "Reported by light"
        case .effect(let id, let parameters):
            guard canMergeReportedValues(session) else { return }
            NeewerEffectCodec.merge(parameters, id: id, kind: light.kind, into: &light.settings)
            light.valuesLabel = "Reported by light"
        }
    }

    private func canMergeReportedValues(_ session: Session) -> Bool {
        Date().timeIntervalSince(session.lastEdit) > 0.5 && session.pendingValue == nil &&
        !session.queue.contains(where: { $0.command.isValueSetting }) && session.inFlight?.command.isValueSetting != true
    }
}
