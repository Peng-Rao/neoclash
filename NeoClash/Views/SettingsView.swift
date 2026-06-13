import NeoClashCore
import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(RuntimeStore.self) private var runtime
    @AppStorage("mixedPort") private var mixedPort = 7897
    @AppStorage("controllerPort") private var controllerPort = 9097
    @AppStorage("autoCloseConnections") private var autoCloseConnections = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Runtime") {
                Stepper(value: $mixedPort, in: 1...65_535) {
                    LabeledContent("Mixed Port", value: "\(mixedPort)")
                }
                Stepper(value: $controllerPort, in: 1...65_535) {
                    LabeledContent("Controller Port", value: "\(controllerPort)")
                }
                Picker("Default Mode", selection: Binding(
                    get: { runtime.mode },
                    set: { runtime.mode = $0 }
                )) {
                    ForEach(RoutingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            Section("Behavior") {
                Toggle("Close connections after node switch", isOn: $autoCloseConnections)
                Toggle("Launch at login", isOn: $launchAtLogin)
                Toggle("System Proxy", isOn: Binding(
                    get: { runtime.isSystemProxyEnabled },
                    set: { runtime.isSystemProxyEnabled = $0 }
                ))
                Toggle("TUN", isOn: Binding(
                    get: { runtime.isTUNEnabled },
                    set: { runtime.isTUNEnabled = $0 }
                ))
            }

            Section("Diagnostics") {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(runtime.diagnosticText, forType: .string)
                } label: {
                    Label("Copy Diagnostics", systemImage: "doc.on.doc")
                }
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .frame(minWidth: 520, minHeight: 420)
        .navigationTitle("Settings")
    }
}
