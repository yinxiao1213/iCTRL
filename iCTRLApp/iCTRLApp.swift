import SwiftUI

@main
struct iCTRLApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var permission = NetworkPermission()
    /// Clients and log of the runner on this device; shared by Settings and Logs.
    @StateObject private var runnerAdmin: RunnerAdmin
    @StateObject private var scriptStore = ScriptStore()
    @StateObject private var scriptController: ScriptController
    @State private var showPermissionAlert = false
    /// Outcome of a pairing file shared to the app, shown as an alert.
    @State private var sharedPairing: SharedPairingResult?

    struct SharedPairingResult: Identifiable {
        let id = UUID()
        let fileName: String
        let error: String?
    }

    init() {
        // Touch the logger during init so every run produces a file, even one
        // that crashes before the user does anything.
        ictrlLog("App launched")
        let admin = RunnerAdmin(port: 8200)
        _runnerAdmin = StateObject(wrappedValue: admin)
        _scriptController = StateObject(wrappedValue: ScriptController(admin: admin))
    }

    /// ictrl-app://run?id=<script id>, from a Home Screen shortcut.
    private func runScript(from url: URL) {
        guard url.host == "run",
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value,
              let id = UUID(uuidString: raw) else { return }
        guard let script = scriptStore.script(id: id) else {
            scriptController.notice = "找不到這個腳本，可能已經刪除了。"
            return
        }
        Task { await scriptController.runFromLink(script) }
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                ScriptListView()
                    .tabItem { Label("腳本", systemImage: "play.square.stack") }
                NavigationStack {
                    SettingsView()
                        .environmentObject(appState)
                }
                .tabItem { Label("設定", systemImage: "gearshape") }
            }
            .environmentObject(appState)
            .environmentObject(runnerAdmin)
            .environmentObject(scriptStore)
            .environmentObject(scriptController)
            .sheet(item: $appState.pendingAuthRequest) { request in
                AuthRequestView(request: request)
                    .environmentObject(appState)
            }
            // A pairing file shared to iCTRL from another app (Files, Mail,
            // AirDrop, a chat): validate, store, and say so either way.
            .onOpenURL { url in
                guard url.isFileURL else {
                    runScript(from: url)
                    return
                }
                let name = url.lastPathComponent
                do {
                    try PairingFileStore.importShared(from: url)
                    ictrlLog("Pairing file received via share: \(name)")
                    sharedPairing = SharedPairingResult(fileName: name, error: nil)
                } catch {
                    ictrlLog("Shared file \(name) rejected: \(error.localizedDescription)")
                    sharedPairing = SharedPairingResult(fileName: name, error: error.localizedDescription)
                }
            }
            .alert(item: $sharedPairing) { result in
                if let error = result.error {
                    return Alert(title: Text(L10n.t(.pairingRejectedTitle)),
                                 message: Text("\(result.fileName)\n\n\(error)"),
                                 dismissButton: .default(Text(L10n.t(.doneButton))))
                }
                return Alert(title: Text(L10n.t(.pairingReceivedTitle)),
                             message: Text(String(format: L10n.t(.pairingReceivedBody), result.fileName)),
                             dismissButton: .default(Text(L10n.t(.doneButton))))
            }
            // On a fresh install this raises the system prompts; afterwards it
            // only reads them back, and a denial is said once per launch.
            .task { permission.probe() }
            .onReceive(permission.$networkData.combineLatest(permission.$localNetwork)) { _ in
                if !permission.denied.isEmpty { showPermissionAlert = true }
            }
            .alert(L10n.t(.networkPermissionTitle), isPresented: $showPermissionAlert) {
                Button(L10n.t(.openSettings)) {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
                Button(L10n.t(.laterButton), role: .cancel) {}
            } message: {
                Text(String(format: L10n.t(.networkPermissionBody), permission.denied.joined(separator: ", ")))
            }
        }
    }
}
