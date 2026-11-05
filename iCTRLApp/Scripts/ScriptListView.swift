import SwiftUI
import UIKit

/// The app's first tab: everything needed to get ready, then the scripts.
struct ScriptListView: View {
    @EnvironmentObject private var store: ScriptStore
    @EnvironmentObject private var controller: ScriptController
    @EnvironmentObject private var admin: RunnerAdmin
    @StateObject private var runner = RunnerStatus(port: 8200)
    @State private var ddi = DeveloperDiskImage.status()
    @State private var showMount = false
    @State private var path: [UUID] = []
    @State private var startFailed = false

    /// The runner can't start without the image, so a running one proves it.
    private var imageReady: Bool { ddi.isMounted || runner.isRunning }
    private var ready: Bool { runner.isRunning && admin.isPaired }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !ready { setupSection }
                progressSection
                scriptsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("腳本")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        let script = SavedScript(name: "新腳本 \(store.scripts.count + 1)")
                        store.save(script)
                        path.append(script.id)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新增腳本")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let script = store.script(id: id) {
                    ScriptEditorView(script: script, ready: ready)
                }
            }
        }
        .onAppear {
            ddi = DeveloperDiskImage.status()
            runner.startPolling()
            Task { await controller.refresh() }
        }
        .onDisappear { runner.stopPolling() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            ddi = DeveloperDiskImage.status()
            Task {
                await runner.check()
                await controller.refresh()
            }
        }
        .sheet(isPresented: $showMount, onDismiss: { ddi = DeveloperDiskImage.status() }) {
            DDIMountView()
        }
    }

    private var setupSection: some View {
        Section {
            SetupRow(number: 1, title: "掛載開發者映像", done: imageReady,
                     detail: "手機重開機後要再做一次。", action: "掛載") {
                showMount = true
            }
            SetupRow(number: 2, title: "啟動自動化服務", done: runner.isRunning,
                     detail: startFailed ? "打不開，請確認 iCTRLUITests-Runner 已安裝。" : "畫面會閃一下，再自動回來。",
                     action: "啟動", enabled: imageReady) {
                UIApplication.shared.open(ScriptController.startRunnerURL) { startFailed = !$0 }
            }
            SetupRow(number: 3, title: "連接 App 和服務", done: admin.isPaired,
                     detail: admin.pairing ? "下拉通知，長按 iCTRL 的通知，按「✅ 允許」。" : "只要做一次。",
                     action: admin.pairing ? "等待中" : "連接", enabled: runner.isRunning && !admin.pairing) {
                Task { await admin.connect() }
            }
            if let notice = admin.notice {
                Text(notice).font(.footnote).foregroundColor(.orange)
            }
        } header: {
            Text("準備")
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        if let notice = controller.notice {
            Section {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundColor(.orange)
            }
        }
        if let progress = controller.progress {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.headline(progress)).font(.subheadline.weight(.semibold))
                    if let error = progress.error {
                        Text(error).font(.footnote).foregroundColor(.red)
                    } else if let detail = progress.detail {
                        Text(detail).font(.footnote).foregroundColor(.secondary)
                    }
                }
                if progress.isActive {
                    Button("停止", role: .destructive) {
                        Task { await controller.stop() }
                    }
                }
            } header: {
                Text("執行狀態")
            } footer: {
                if progress.isActive { Text("在別的畫面時，按側邊鍵鎖定手機就能停止。") }
            }
        }
    }

    private static func headline(_ p: ScriptController.Progress) -> String {
        switch p.state {
        case "running":
            let round = p.loops == 1 ? "" : "第 \(p.loop) 輪，"
            return "「\(p.name)」\(round)第 \(p.stepIndex + 1) / \(p.stepCount) 步"
        case "stopping": return "「\(p.name)」停止中…"
        case "finished": return "「\(p.name)」跑完了"
        case "failed": return "「\(p.name)」失敗"
        case "stopped": return "「\(p.name)」已停止"
        default: return p.name
        }
    }

    private var scriptsSection: some View {
        Section {
            if store.scripts.isEmpty {
                Text("還沒有腳本。按右上角的 + 新增一個。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(store.scripts) { script in
                HStack(spacing: 12) {
                    NavigationLink(value: script.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(script.name)
                            Text("\(script.steps.count) 步")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Button {
                        Task { await controller.run(script) }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!ready || script.steps.isEmpty || controller.progress?.isActive == true)
                    .accessibilityLabel("執行\(script.name)")
                }
            }
            .onDelete { offsets in
                for index in offsets { store.delete(id: store.scripts[index].id) }
            }
        } header: {
            Text("我的腳本")
        }
    }
}

private struct SetupRow: View {
    let number: Int
    let title: String
    let done: Bool
    let detail: String
    let action: String
    var enabled = true
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundColor(done ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !done {
                    Text(detail).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            if !done {
                Button(action, action: perform)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!enabled)
            }
        }
    }
}
