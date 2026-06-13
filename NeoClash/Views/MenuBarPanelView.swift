import NeoClashCore
import SwiftUI

struct MenuBarPanelView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator
    @AppStorage("mixedPort") private var mixedPort = 7897
    @AppStorage("controllerPort") private var controllerPort = 9097

    var body: some View {
        @Bindable var runtime = runtime

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(runtime.status.isRunning ? .green : .secondary)
                    .frame(width: 9, height: 9)
                Text(runtime.status.label)
                    .font(.headline)
                Spacer()
            }

            HStack {
                Label(runtime.traffic.uploadPerSecond.bytesPerSecondString, systemImage: "arrow.up")
                Spacer()
                Label(runtime.traffic.downloadPerSecond.bytesPerSecondString, systemImage: "arrow.down")
            }
            .font(.caption.monospacedDigit())

            Picker("Mode", selection: $runtime.mode) {
                ForEach(RoutingMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Divider()

            Button {
                Task {
                    if runtime.status.isRunning {
                        await coordinator.stop()
                    } else {
                        await coordinator.start(mixedPort: mixedPort, controllerPort: controllerPort)
                    }
                }
            } label: {
                Label(runtime.status.isRunning ? "Stop" : "Start", systemImage: runtime.status.isRunning ? "stop.fill" : "play.fill")
            }

            Toggle("System Proxy", isOn: $runtime.isSystemProxyEnabled)
            Toggle("TUN", isOn: $runtime.isTUNEnabled)
        }
        .padding(14)
        .frame(width: 280)
    }
}
