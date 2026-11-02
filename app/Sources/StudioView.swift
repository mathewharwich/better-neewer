import AppKit
import SwiftUI

private let secondaryInk = Color(nsColor: .secondaryLabelColor)
private let studioCardFill = Color(nsColor: .controlBackgroundColor)

private struct StudioContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

@MainActor
struct StudioView: View {
    @ObservedObject var controller: StudioController
    let maximumHeight: CGFloat
    var heightChanged: (CGFloat) -> Void = { _ in }
    var openWindow: () -> Void = {}
    var isWindow = false
    @State private var contentHeight: CGFloat = 600
    @State private var advancedLight: UUID?
    @State private var renaming: LightState?
    @State private var addingLights = false
    @State private var removing: LightState?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 13) {
                header
                if controller.lights.isEmpty {
                    emptyStudio
                } else {
                    VStack(spacing: 9) {
                        ForEach(controller.lights) { light in
                            StudioLightCard(controller: controller, light: light,
                                            advanced: advancedLight == light.id,
                                            toggleAdvanced: {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    advancedLight = advancedLight == light.id ? nil : light.id
                                }
                            }, rename: { renaming = light }, remove: { removing = light })
                        }
                    }
                }
                HStack(spacing: 5) {
                    Text("Better Neewer").font(.system(size: 10, weight: .medium))
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                        .font(.system(size: 10)).monospacedDigit()
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                        .font(.system(size: 11)).buttonStyle(.plain)
                        .accessibilityLabel("Quit Better Neewer")
                }
                .foregroundStyle(secondaryInk)
            }
            .padding(16)
            .frame(width: 420)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geo in
                Color.clear.preference(key: StudioContentHeight.self, value: geo.size.height)
            })
        }
        .frame(width: 420, height: min(maximumHeight, contentHeight))
        .background(Color(nsColor: .windowBackgroundColor))
        .onPreferenceChange(StudioContentHeight.self) { height in
            guard height > 0 else { return }
            contentHeight = ceil(height)
            heightChanged(min(maximumHeight, ceil(height)))
        }
        .sheet(item: $renaming) { light in
            RenameLightSheet(light: light) { controller.saveName(light) }
        }
        .sheet(isPresented: $addingLights) { AddLightsSheet(controller: controller) }
        .alert("Remove this light?", isPresented: Binding(get: { removing != nil }, set: {
            if !$0 { removing = nil }
        }), presenting: removing) { light in
            Button("Remove", role: .destructive) {
                controller.remove(light)
                if advancedLight == light.id { advancedLight = nil }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { light in
            Text("\(light.displayName)'s saved name and settings will be removed. Its current light output will stay unchanged.")
        }
    }

    private func showAddLights() {
        addingLights = true
        controller.scan()
    }

    private var emptyStudio: some View {
        VStack(spacing: 11) {
            Image(systemName: "lightbulb")
                .font(.system(size: 28, weight: .ultraLight)).foregroundStyle(secondaryInk)
                .accessibilityHidden(true)
            Text("Your lights, together").font(.system(size: 14, weight: .semibold))
            Text("Add a supported NEEWER light to get started.")
                .font(.system(size: 11)).foregroundStyle(secondaryInk).multilineTextAlignment(.center)
            Button("Add lights", action: showAddLights)
                .buttonStyle(.borderedProminent).controlSize(.small)
                .accessibilityIdentifier("add-first-light")
        }
        .padding(.vertical, 28).frame(maxWidth: .infinity)
        .background(studioCardFill, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lightbulb.2")
                .font(.system(size: 22, weight: .light)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Studio lights").font(.system(size: 17, weight: .semibold))
                HStack(spacing: 5) {
                    if controller.isScanning {
                        ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
                    }
                    Text(controller.bluetoothStatus).font(.system(size: 10)).lineLimit(2)
                }
                .foregroundStyle(secondaryInk)
            }
            Spacer(minLength: 0)
            Button(action: showAddLights) {
                Image(systemName: "plus.circle").font(.system(size: 17)).foregroundStyle(secondaryInk)
            }
            .buttonStyle(.plain).help("Add lights")
            .accessibilityLabel("Add lights").accessibilityIdentifier("add-lights")
            Menu {
                Button("Add lights…", action: showAddLights)
                Divider()
                Button("Connect all lights") { controller.connectAll() }
                    .disabled(controller.lights.isEmpty)
                Button("Refresh connected lights") {
                    for light in controller.lights where light.canControl { controller.refresh(light) }
                }
                .disabled(!controller.lights.contains(where: \.canControl))
                Divider()
                if !isWindow { Button("Open control window", action: openWindow) }
                Button("Quit Better Neewer") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 17)).foregroundStyle(secondaryInk)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Studio options")
        }
    }
}

@MainActor
private struct StudioLightCard: View {
    @ObservedObject var controller: StudioController
    @ObservedObject var light: LightState
    let advanced: Bool
    let toggleAdvanced: () -> Void
    let rename: () -> Void
    let remove: () -> Void

    private var activeEffect: EffectDefinition? {
        EffectCatalog.effects(for: light.kind).first { $0.id == light.settings.effectID }
    }
    private var activeModeLabel: String {
        switch light.settings.mode {
        case .white: "White"
        case .color: "Color"
        case .effects: activeEffect?.name ?? "Effects"
        }
    }
    private var powerLabel: String {
        if let pending = light.requestedPower { return pending ? "Turning on…" : "Turning off…" }
        if let reported = light.reportedPower { return reported ? "On" : "Off" }
        return "Power unknown"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: light.kind.symbol)
                    .font(.system(size: 15, weight: .light)).frame(width: 19)
                    .foregroundStyle(light.kind.supportsColor ? Color.purple.opacity(0.8) : Color.primary.opacity(0.7))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(light.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if light.displayName != light.kind.name {
                        Text(light.kind.name).font(.system(size: 9)).foregroundStyle(secondaryInk)
                    }
                }
                .contextMenu {
                    Button("Rename…", action: rename)
                    if light.connection == .disconnected {
                        Button("Connect") { controller.connect(light) }
                    } else {
                        Button("Refresh") { controller.refresh(light) }.disabled(!light.canControl)
                        Button("Disconnect") { controller.disconnect(light) }
                    }
                    Divider()
                    Button("Remove light…", role: .destructive, action: remove)
                }
                Spacer(minLength: 0)
                Text(powerLabel).font(.system(size: 9)).foregroundStyle(secondaryInk).lineLimit(1)
                    .accessibilityIdentifier("\(light.id.uuidString)-power-status")
                Toggle("Power", isOn: Binding(get: {
                    light.requestedPower ?? light.reportedPower ?? false
                }, set: { controller.setPower(light, on: $0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .disabled(!light.canControl || light.reportedPower == nil || light.requestedPower != nil)
                .accessibilityLabel("\(light.displayName) power")
                .accessibilityValue(powerLabel)
                .accessibilityIdentifier("\(light.id.uuidString)-power")
            }
            .padding(.horizontal, 13).padding(.vertical, 9)

            Divider().padding(.horizontal, 13)
            VStack(alignment: .leading, spacing: 8) {
                StudioValueSlider(label: "Brightness", value: setting(\.brightness) { applyCurrentMode() },
                                  range: 0...100, step: 1, unit: "%", light: light,
                                  identifier: "\(light.id.uuidString)-brightness")
                    .disabled(!light.canControl)
                StudioValueSlider(label: "White temp.", value: setting(\.kelvin) {
                    light.settings.mode = .white
                    controller.applyWhite(light)
                }, range: 2700...6500, step: 100, unit: "K", light: light,
                                  identifier: "\(light.id.uuidString)-temperature")
                    .disabled(!light.canControl)

                if light.kind.supportsBoost { boostControl.padding(.top, 3).disabled(!light.canControl) }

                HStack(spacing: 4) {
                    Button(action: toggleAdvanced) {
                        HStack(spacing: 4) {
                            Text(light.kind.supportsColor ? "Color & effects" : "Effects")
                            Image(systemName: advanced ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(advanced ? "Hide" : "Show") \(light.displayName) advanced controls")
                    .accessibilityIdentifier("\(light.id.uuidString)-expand")
                    Spacer()
                    Text(activeModeLabel).lineLimit(1)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityLabel("Selected mode: \(activeModeLabel)")
                }
                .font(.system(size: 10)).foregroundStyle(secondaryInk)
                .padding(.top, 2)

                if advanced {
                    Divider().padding(.vertical, 2)
                    advancedControls.disabled(!light.canControl)
                }
            }
            .padding(.horizontal, 14).padding(.top, 9).padding(.bottom, 9)

            HStack(spacing: 5) {
                Circle().fill(light.canControl ? Color.green : Color.secondary.opacity(0.5)).frame(width: 4, height: 4)
                    .accessibilityHidden(true)
                Text(light.connection.label).lineLimit(1)
                Text("·").accessibilityHidden(true)
                Text(light.valuesLabel).lineLimit(1)
                    .help("Brightness, temperature and color values are remembered or requested unless explicitly reported by the light.")
                Spacer(minLength: 4)
                if light.connection == .disconnected {
                    Button("Connect") { controller.connect(light) }
                        .accessibilityLabel("Connect \(light.displayName)")
                        .accessibilityIdentifier("\(light.id.uuidString)-connect")
                } else if !light.canControl {
                    Button("Cancel") { controller.disconnect(light) }
                        .accessibilityLabel("Cancel connection to \(light.displayName)")
                } else {
                    Button { controller.refresh(light) } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh \(light.displayName)")
                        .accessibilityIdentifier("\(light.id.uuidString)-refresh")
                        .help("Read this light's status")
                }
            }
            .font(.system(size: 9)).foregroundStyle(secondaryInk).buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.bottom, 10)

            if let error = light.error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 10)).foregroundStyle(.orange).lineLimit(4)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            } else if let message = light.message, !message.isEmpty {
                Text(message).font(.system(size: 10)).foregroundStyle(secondaryInk).lineLimit(3)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
        .background(studioCardFill, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .strokeBorder(Color.primary.opacity(advanced ? 0.12 : 0.07), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(light.displayName) controls")
    }

    @ViewBuilder private var boostControl: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Output mode").font(.system(size: 11, weight: .medium))
                if let requested = light.requestedBoost {
                    Text(requested ? "Enabling Boost…" : "Enabling Silent…")
                        .font(.system(size: 9)).foregroundStyle(secondaryInk)
                } else if let boost = light.reportedBoost {
                    Text(boost ? "Higher output · fan enabled" : "Lower output · fan off")
                        .font(.system(size: 9)).foregroundStyle(secondaryInk)
                } else {
                    Text("Boost state unknown").font(.system(size: 9)).foregroundStyle(secondaryInk)
                }
            }
            Spacer(minLength: 0)
            if let reported = light.reportedBoost {
                Picker("Output mode", selection: Binding(get: {
                    light.requestedBoost ?? reported
                }, set: { controller.setBoost(light, enabled: $0) })) {
                    Text("Silent").tag(false)
                    Text("Boost").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 154)
                .disabled(!light.canBoost || light.requestedBoost != nil)
                .help(light.canBoost ? "Switch between Silent and Boost output modes."
                      : "Boost switching has only been verified on CB200B firmware 1.1.5.")
                .accessibilityIdentifier("\(light.id.uuidString)-output-mode")
            } else {
                Text("Silent / Boost").font(.system(size: 10)).foregroundStyle(secondaryInk)
                    .accessibilityIdentifier("\(light.id.uuidString)-output-mode-unknown")
            }
        }
    }

    @ViewBuilder private var advancedControls: some View {
        VStack(spacing: 12) {
            if light.kind.supportsColor {
                Picker("Mode", selection: Binding(get: { light.settings.mode }, set: { mode in
                    light.settings.mode = mode
                    applyCurrentMode()
                })) {
                    ForEach(ControlMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityIdentifier("\(light.id.uuidString)-mode")
            } else {
                Picker("Mode", selection: Binding(get: { light.settings.mode }, set: { mode in
                    light.settings.mode = mode
                    applyCurrentMode()
                })) {
                    Text("White").tag(ControlMode.white)
                    Text("Effects").tag(ControlMode.effects)
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityIdentifier("\(light.id.uuidString)-mode")
            }

            switch light.settings.mode {
            case .white:
                if light.kind.supportsColor {
                    advancedSlider("Tint", key: \.tint, range: -50...50, unit: "", step: 1) {
                        controller.applyWhite(light)
                    }
                }
            case .color:
                colorControls
            case .effects:
                effectControls
            }
        }
    }

    private var colorControls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hue: light.settings.hue / 360, saturation: light.settings.saturation / 100,
                                brightness: max(0.08, light.settings.brightness / 100)))
                    .frame(width: 24, height: 24)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                    .accessibilityLabel("Requested color")
                Text("Color").font(.system(size: 11, weight: .medium))
                Spacer()
            }
            advancedSlider("Hue", key: \.hue, range: 0...360, unit: "°", step: 1) { controller.applyColor(light) }
            advancedSlider("Saturation", key: \.saturation, range: 0...100, unit: "%", step: 1) { controller.applyColor(light) }
        }
    }

    private var effectControls: some View {
        VStack(spacing: 9) {
            HStack {
                Text("Effect").font(.system(size: 11, weight: .medium))
                Spacer()
                Picker("Effect", selection: Binding(get: { light.settings.effectID }, set: { id in
                    light.settings.effectID = id
                    // Color-option domains differ per effect. Reset only after an
                    // explicit selection, never when loading or displaying the UI.
                    light.settings.colorOption = 0
                    light.settings.mode = .effects
                    controller.applyEffect(light)
                })) {
                    ForEach(EffectCatalog.effects(for: light.kind)) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(width: 190)
                .accessibilityIdentifier("\(light.id.uuidString)-effect")
            }
            if let effect = activeEffect {
                effectParameters(effect)
            } else {
                Text("Choose a supported effect.").font(.system(size: 10)).foregroundStyle(secondaryInk)
            }
        }
    }

    @ViewBuilder private func effectParameters(_ effect: EffectDefinition) -> some View {
        let parameters = effect.parameters
        if parameters.contains(.color), !effect.colorOptions.isEmpty {
            HStack {
                Text("Color mode").font(.system(size: 11, weight: .medium))
                Spacer()
                Picker("Color mode", selection: Binding(get: { light.settings.colorOption }, set: {
                    light.settings.colorOption = $0
                    controller.applyEffect(light)
                })) {
                    ForEach(Array(effect.colorOptions.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(index)
                    }
                }
                .labelsHidden().frame(width: 190)
                .accessibilityIdentifier("\(light.id.uuidString)-effect-color")
            }
        }
        if parameters.contains(.brightnessUpper) {
            advancedSlider("Lower bright.", key: \.brightness, range: 0...light.settings.brightnessUpper,
                           unit: "%", step: 1) { controller.applyEffect(light) }
            advancedSlider("Upper bright.", key: \.brightnessUpper, range: light.settings.brightness...100,
                           unit: "%", step: 1) { controller.applyEffect(light) }
        }
        if parameters.contains(.temperature), effect.id != 14 || !light.kind.supportsColor || light.settings.colorOption == 0 {
            advancedSlider(parameters.contains(.temperatureUpper) ? "Lower temp." : "Effect temp.", key: \.kelvin,
                           range: 2700...(parameters.contains(.temperatureUpper) ? light.settings.kelvinUpper : 6500),
                           unit: "K", step: 100) { controller.applyEffect(light) }
        }
        if parameters.contains(.temperatureUpper) {
            advancedSlider("Upper temp.", key: \.kelvinUpper, range: light.settings.kelvin...6500,
                           unit: "K", step: 100) { controller.applyEffect(light) }
        }
        if parameters.contains(.tint) {
            advancedSlider("Tint", key: \.tint, range: -50...50, unit: "", step: 1) { controller.applyEffect(light) }
        }
        if parameters.contains(.hue), effect.id != 14 || light.settings.colorOption == 1 {
            advancedSlider(parameters.contains(.hueUpper) ? "Lower hue" : "Hue", key: \.hue,
                           range: 0...(parameters.contains(.hueUpper) ? light.settings.hueUpper : 360),
                           unit: "°", step: 1) { controller.applyEffect(light) }
        }
        if parameters.contains(.hueUpper) {
            advancedSlider("Upper hue", key: \.hueUpper, range: light.settings.hue...360,
                           unit: "°", step: 1) { controller.applyEffect(light) }
        }
        if parameters.contains(.saturation) {
            advancedSlider("Saturation", key: \.saturation, range: 0...100, unit: "%", step: 1) { controller.applyEffect(light) }
        }
        if parameters.contains(.speed) {
            advancedSlider("Speed", key: \.speed, range: 1...10, unit: "", step: 1) { controller.applyEffect(light) }
        }
        if parameters.contains(.sparks) {
            advancedSlider("Sparks", key: \.sparks, range: 1...10, unit: "", step: 1) { controller.applyEffect(light) }
        }
    }

    private func advancedSlider(_ label: String, key: WritableKeyPath<RememberedSettings, Double>,
                                range: ClosedRange<Double>, unit: String, step: Double,
                                action: @escaping () -> Void) -> some View {
        StudioValueSlider(label: label, value: setting(key, action: action), range: range, step: step,
                          unit: unit, light: light, identifier: "\(light.id.uuidString)-advanced-\(label)")
    }

    private func setting(_ key: WritableKeyPath<RememberedSettings, Double>,
                         action: @escaping () -> Void) -> Binding<Double> {
        Binding(get: { light.settings[keyPath: key] }, set: { value in
            light.settings[keyPath: key] = value
            // Keep interval endpoints valid when an always-visible basic slider
            // changes the lower endpoint of an active effect.
            light.settings.brightnessUpper = max(light.settings.brightnessUpper, light.settings.brightness)
            light.settings.kelvinUpper = max(light.settings.kelvinUpper, light.settings.kelvin)
            light.settings.hueUpper = max(light.settings.hueUpper, light.settings.hue)
            action()
        })
    }

    private func applyCurrentMode() {
        switch light.settings.mode {
        case .white: controller.applyWhite(light)
        case .color: controller.applyColor(light)
        case .effects: controller.applyEffect(light)
        }
    }
}

@MainActor
private struct StudioValueSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    @ObservedObject var light: LightState
    let identifier: String
    @State private var draft = ""
    @FocusState private var editing: Bool

    private func commit() {
        if let parsed = Double(draft.trimmingCharacters(in: .whitespaces)), parsed.isFinite {
            let clamped = min(range.upperBound, max(range.lowerBound, (parsed / step).rounded() * step))
            if clamped != value { value = clamped }
        }
        draft = String(Int(value))
    }

    var body: some View {
        HStack(spacing: 9) {
            Text(label).font(.system(size: 11, weight: .medium)).frame(width: 77, alignment: .leading)
            if range.lowerBound < range.upperBound {
                Slider(value: $value, in: range, step: step)
                    .controlSize(.small)
                    .accessibilityLabel("\(light.displayName) \(label) slider")
                    .accessibilityValue("\(Int(value)) \(unit)")
                    .accessibilityIdentifier("\(identifier)-slider")
            } else {
                Slider(value: .constant(range.lowerBound), in: range.lowerBound...(range.upperBound + step))
                    .controlSize(.small).disabled(true)
                    .accessibilityLabel("\(label), fixed endpoint")
            }
            HStack(spacing: 3) {
                TextField(label, text: $draft)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .multilineTextAlignment(.trailing).textFieldStyle(.plain)
                    .frame(width: unit == "K" ? 35 : 27)
                    .focused($editing).onSubmit { commit(); editing = false }
                    .accessibilityLabel("\(light.displayName) \(label) \(unit == "K" ? "in Kelvin" : unit == "%" ? "percent" : "value")")
                    .accessibilityIdentifier("\(identifier)-field")
                if !unit.isEmpty { Text(unit).font(.system(size: 10)).foregroundStyle(secondaryInk) }
            }
            .frame(width: 49, alignment: .trailing)
            .padding(.horizontal, 5).padding(.vertical, 4)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(editing ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1))
        }
        .frame(height: 22)
        .onAppear { draft = String(Int(value)) }
        .onChange(of: value) { _, updated in if !editing { draft = String(Int(updated)) } }
        .onChange(of: editing) { _, focused in if !focused { commit() } }
    }
}

@MainActor
private struct AddLightsSheet: View {
    @ObservedObject var controller: StudioController
    @Environment(\.dismiss) private var dismiss
    @State private var manualAddresses: [UUID: String] = [:]
    @State private var expandedAddresses: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Add lights").font(.system(size: 17, weight: .semibold))
                Spacer()
                if controller.isScanning { ProgressView().controlSize(.small) }
            }
            Text("Turn on your light's mains power and select its Bluetooth / App mode.")
                .font(.system(size: 11)).foregroundStyle(secondaryInk)
            Text("Supports CB60B, CB60 RGB and CB200B.")
                .font(.system(size: 10)).foregroundStyle(secondaryInk)

            ScrollView {
                if controller.availableLights.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 25, weight: .ultraLight)).foregroundStyle(secondaryInk)
                            .accessibilityHidden(true)
                        Text(controller.isScanning ? "Looking for nearby lights…" : "No new lights found")
                            .font(.system(size: 12, weight: .medium))
                        Text("Already added lights appear in your studio.")
                            .font(.system(size: 10)).foregroundStyle(secondaryInk)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 38)
                } else {
                    VStack(spacing: 8) {
                        ForEach(controller.availableLights) { candidate in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack(spacing: 10) {
                                    Image(systemName: candidate.kind.symbol)
                                        .font(.system(size: 18, weight: .light)).frame(width: 26)
                                        .foregroundStyle(secondaryInk).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(candidate.kind.name).font(.system(size: 12, weight: .semibold))
                                        Text(detail(for: candidate)).font(.system(size: 9)).foregroundStyle(secondaryInk)
                                            .lineLimit(1)
                                        if candidate.mac == nil {
                                            Text("Connect to finish setup").font(.system(size: 9)).foregroundStyle(secondaryInk)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                    Button("Add & connect") {
                                        let entered = manualAddresses[candidate.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                                        controller.addLight(candidate, macAddress: entered.isEmpty ? nil : entered)
                                    }
                                    .controlSize(.small)
                                    .disabled(controller.lights.contains { $0.id == candidate.id })
                                    .accessibilityLabel("Add and connect \(candidate.kind.name), ID ending \(candidate.id.uuidString.suffix(4))")
                                    .accessibilityIdentifier("add-\(candidate.id.uuidString)")
                                }
                                if candidate.mac == nil {
                                    DisclosureGroup("Bluetooth address (optional)", isExpanded: Binding(get: {
                                        expandedAddresses.contains(candidate.id)
                                    }, set: { expanded in
                                        if expanded { expandedAddresses.insert(candidate.id) }
                                        else { expandedAddresses.remove(candidate.id) }
                                    })) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            TextField("02:11:22:33:44:55", text: Binding(get: {
                                                manualAddresses[candidate.id, default: ""]
                                            }, set: { manualAddresses[candidate.id] = $0 }))
                                            .textFieldStyle(.roundedBorder).font(.system(size: 11).monospaced())
                                            .accessibilityLabel("\(candidate.kind.name) optional Bluetooth address")
                                            Text("Leave blank to use local Bluetooth device info. Enter an address if automatic setup cannot finish.")
                                                .font(.system(size: 9)).foregroundStyle(secondaryInk)
                                        }
                                        .padding(.top, 6)
                                    }
                                    .font(.system(size: 10)).foregroundStyle(secondaryInk)
                                }
                            }
                            .padding(11)
                            .background(studioCardFill, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
                        }
                    }
                }
            }
            .frame(minHeight: 150, maxHeight: 260)

            Text(controller.enrollmentStatus).font(.system(size: 10)).foregroundStyle(secondaryInk)
                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
            HStack {
                Button("Scan again") { controller.scan() }
                    .disabled(controller.isScanning).accessibilityIdentifier("scan-for-lights")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 420)
    }

    private func detail(for candidate: DiscoveredLight) -> String {
        let signal: String
        if let rssi = candidate.rssi, (-127...0).contains(rssi) {
            signal = rssi >= -65 ? "Strong signal" : rssi >= -80 ? "Fair signal" : "Weak signal"
        } else { signal = "Nearby light" }
        return "\(signal) · ID …\(candidate.id.uuidString.suffix(4))"
    }
}

@MainActor
private struct RenameLightSheet: View {
    @ObservedObject var light: LightState
    let save: () -> Void
    @State private var draft: String
    @Environment(\.dismiss) private var dismiss
    init(light: LightState, save: @escaping () -> Void) {
        self.light = light
        self.save = save
        _draft = State(initialValue: light.displayName)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Rename \(light.kind.name)").font(.headline)
            TextField("Light name", text: $draft).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("light-rename-field")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    light.displayName = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 320)
    }
}
