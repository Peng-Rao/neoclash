import NeoClashMobileCore
import SwiftUI

struct IOSSettingsView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(IOSAppCoordinator.self) private var coordinator
    @AppStorage("mixedPort") private var mixedPort = 7897
    @AppStorage("controllerPort") private var controllerPort = 9097
    @AppStorage("allowLan") private var allowLAN = false
    @AppStorage("coreLogLevel") private var coreLogLevel = CoreLogLevel.error.rawValue

    var body: some View {
        Form {
            Section("Runtime") {
                Picker("Mode", selection: Binding(get: { runtime.mode }, set: { coordinator.setMode($0) })) {
                    ForEach(RoutingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Picker("Log Level", selection: $coreLogLevel) {
                    ForEach(CoreLogLevel.allCases) { level in
                        Text(level.rawValue.capitalized).tag(level.rawValue)
                    }
                }

                Toggle("Allow LAN", isOn: $allowLAN)
            }

            Section("Ports") {
                Stepper("Mixed Port: \(mixedPort)", value: $mixedPort, in: 1...65_535)
                Stepper("Controller Port: \(controllerPort)", value: $controllerPort, in: 1...65_535)
            }

            Section("Packet Tunnel") {
                HStack {
                    Text("Provider")
                    Spacer()
                    Text(IOSTunnelController.providerBundleIdentifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("App Group")
                    Spacer()
                    Text(IOSTunnelController.appGroupIdentifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Button("Refresh VPN State") {
                    Task { await coordinator.refreshTunnelState() }
                }
            }
        }
        .navigationTitle("Settings")
    }
}
