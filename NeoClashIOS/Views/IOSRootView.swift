import NeoClashMobileCore
import SwiftUI

enum IOSAppTab: Hashable {
    case home
    case proxies
    case activity
    case profiles
    case settings
}

struct IOSRootView: View {
    @Environment(IOSAppCoordinator.self) private var coordinator
    @State private var selection: IOSAppTab = .home

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "bolt.horizontal.fill", value: IOSAppTab.home) {
                NavigationStack {
                    IOSHomeView(selection: $selection)
                }
            }
            Tab("Proxies", systemImage: "point.3.connected.trianglepath.dotted", value: IOSAppTab.proxies) {
                NavigationStack {
                    IOSProxiesView()
                }
            }
            Tab("Activity", systemImage: "waveform.path.ecg", value: IOSAppTab.activity) {
                NavigationStack {
                    IOSActivityView()
                }
            }
            Tab("Profiles", systemImage: "doc.text", value: IOSAppTab.profiles) {
                NavigationStack {
                    IOSProfilesView()
                }
            }
            Tab("Settings", systemImage: "gearshape", value: IOSAppTab.settings) {
                NavigationStack {
                    IOSSettingsView()
                }
            }
        }
        .tint(NC.indigo)
        .alert("Something went wrong", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(coordinator.lastError ?? "")
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding {
            coordinator.lastError != nil
        } set: { isPresented in
            if !isPresented {
                coordinator.lastError = nil
            }
        }
    }
}
