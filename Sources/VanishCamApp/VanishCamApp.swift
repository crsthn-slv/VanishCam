import SwiftUI
import AppKit
import ServiceManagement
import VanishCore

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings { didSet { store.settings = settings; settingsDidChange() } }
    @Published var phase = "stopped"
    @Published var needsRoom = false
    @Published var active = false
    @Published var statusMessage: String?

    let store = SettingsStore()
    let engine = CameraEngine()
    private var didStart = false

    init() {
        _settings = Published(initialValue: store.settings)
        engine.onTick = { [weak self] in   // publish only on change: a redraw every second breaks menu hover
            guard let self else { return }
            if phase != engine.phaseName { phase = engine.phaseName }
            if needsRoom != engine.needsRoomCapture { needsRoom = engine.needsRoomCapture }
            if active != engine.active { active = engine.active }
        }
        startEngine()
    }

    func startEngine() {
        let cams = CameraEngine.availableCameras()
        let dev = settings.cameraName.flatMap { name in cams.first { $0.localizedName == name } }
            ?? settings.cameraIndex.flatMap { i in cams.indices.contains(i) ? cams[i] : nil }
            ?? cams.first
        do { try engine.start(settings: settings, camera: dev); didStart = true; statusMessage = nil }
        catch { statusMessage = error.localizedDescription }
    }

    private func settingsDidChange() {
        if didStart { engine.apply(settings: settings) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() } }
            else if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        } catch { statusMessage = "Login item failed: \(error.localizedDescription)" }
    }
}

@main
struct VanishCamApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        // hidden while the camera is off; stays visible on errors so they aren't silent
        MenuBarExtra(isInserted: Binding(get: { model.active || model.statusMessage != nil }, set: { _ in })) {
            MenuContent(model: model)
        } label: {
            // calibrating = needs an empty room: tell the user to step out
            Image(systemName: !model.engine.running || !model.active ? "video.slash"
                  : model.phase == "calibrating" ? "figure.walk.departure"
                  : model.phase == "gone" ? "person.slash" : "person.and.background.dotted")
        }
        .menuBarExtraStyle(.menu)

        Settings { SettingsView(model: model) }
    }
}

private struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let msg = model.statusMessage { Text(msg); Divider() }
        else if !model.active { Text("Waiting for a call (camera off)"); Divider() }
        else if model.phase == "calibrating" { Text("Step out of frame for a few seconds to capture the room"); Divider() }
        else if model.needsRoom { Text("No room captured: click Recapture Background, then step out"); Divider() }
        EffectToggles(model: model)
        Divider()
        Button("Vanish / Reappear") { model.engine.toggle() }
        Button("Recapture Background") { model.engine.recapture() }
        Divider()
        Button("Settings…") { NSApp.activate(ignoringOtherApps: true); openSettings() }
            .keyboardShortcut(",")
        Button("Quit VanishCam") { NSApp.terminate(nil) }
    }
}

/// One switch per effect: every enabled gesture works at the same time.
private struct EffectToggles: View {
    @ObservedObject var model: AppModel
    var body: some View {
        // ponytail: labels are LocalizedStringKey; add Localizable.xcstrings + copy *.lproj in make_app.sh to translate
        ForEach([(EffectKind.dissolve, LocalizedStringKey("Dissolve: V sign")), (.substitution, "Substitution: hand seal"),
                 (.teleport, "Teleport: two fingers on forehead")], id: \.0) { kind, label in
            Toggle(label, isOn: Binding(get: { !model.settings.disabledEffects.contains(kind) },
                                        set: { on in if on { model.settings.disabledEffects.remove(kind) } else { model.settings.disabledEffects.insert(kind) } }))
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var calibrating = false

    var body: some View {
        Form {
            Picker("Camera", selection: $model.settings.cameraName) {
                ForEach(CameraEngine.availableCameras(), id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.localizedName)) }
            }
            Section("Gestures") {
                EffectToggles(model: model)
                Button("Calibrate gestures…") { calibrating = true }.disabled(!model.engine.running)
                Button("Reset gesture calibration") { model.engine.resetSamples() }
            }
            LabeledContent("Gesture hold time") {
                Slider(value: $model.settings.holdSeconds, in: 0.1...2, step: 0.1)
                Text(String(format: "%.1f s", model.settings.holdSeconds)).monospacedDigit().frame(width: 56, alignment: .trailing)
            }
            LabeledContent("Calibration time") {
                Slider(value: $model.settings.calibrationSeconds, in: 1...10, step: 0.5)
                Text(String(format: "%.1f s", model.settings.calibrationSeconds)).monospacedDigit().frame(width: 56, alignment: .trailing)
            }
            Picker("Resolution", selection: Binding(
                get: { model.settings.outputHeight >= 1080 ? 1080 : 720 },
                set: { model.settings.outputWidth = $0 == 1080 ? 1920 : 1280; model.settings.outputHeight = $0 })) {
                Text("720p").tag(720); Text("1080p").tag(1080)
            }
            Toggle("Sound", isOn: $model.settings.soundEnabled)
            Slider(value: $model.settings.soundVolume, in: 0...1, step: 0.05)
                .disabled(!model.settings.soundEnabled)
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { model.setLaunchAtLogin($0) }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $calibrating) { CalibrationView(model: model) }
        .frame(width: 460, height: 520)
    }
}
