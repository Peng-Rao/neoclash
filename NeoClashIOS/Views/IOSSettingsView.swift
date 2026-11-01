import NeoClashMobileCore
import SwiftUI

struct IOSSettingsView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(IOSAppCoordinator.self) private var coordinator
    @AppStorage("coreLogLevel") private var logLevel = CoreLogLevel.error.rawValue
    @AppStorage("allowLan") private var allowLAN = false
    @AppStorage("mixedPort") private var mixedPort = RuntimePorts().mixedPort
    @AppStorage("controllerPort") private var controllerPort = RuntimePorts().controllerPort

    var body: some View {
        Form {
            Section("Engine") {
                LabeledContent("Status", value: runtime.status.label)
                LabeledContent("Runs in", value: coordinator.engine.routesDeviceTraffic ? "VPN extension" : "This app")
                LabeledContent("Mihomo", value: runtime.status.isRunning ? runtime.coreVersion : EmbeddedCore.version)
            }

            Section {
                Picker("Log level", selection: $logLevel) {
                    ForEach(CoreLogLevel.allCases) { level in
                        Text(level.rawValue.capitalized).tag(level.rawValue)
                    }
                }
                Toggle("Allow LAN connections", isOn: $allowLAN)
                portField("Proxy port", value: $mixedPort)
                portField("Controller port", value: $controllerPort)
            } header: {
                Text("Core")
            } footer: {
                Text("Changes apply the next time NeoClash starts.")
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                Link("Mihomo source code (GPL-3.0)", destination: URL(string: "https://github.com/MetaCubeX/mihomo")!)
            }
        }
        .navigationTitle("Settings")
    }

    private func portField(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number.grouping(.never))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .ncMono(.body, weight: .regular)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }
}
