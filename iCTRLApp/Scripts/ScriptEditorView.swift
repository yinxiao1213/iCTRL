import SwiftUI
import UIKit

/// One script: its settings, its steps, and the way into recording.
struct ScriptEditorView: View {
    @EnvironmentObject private var store: ScriptStore
    @EnvironmentObject private var controller: ScriptController
    @EnvironmentObject private var admin: RunnerAdmin
    @Environment(\.dismiss) private var dismiss

    let ready: Bool
    @State private var draft: SavedScript
    @State private var recording = false
    @State private var editing: ScriptStep?
    @State private var linkCopied = false

    init(script: SavedScript, ready: Bool) {
        _draft = State(initialValue: script)
        self.ready = ready
    }

    private var startsInAnApp: Bool {
        guard let first = draft.steps.first else { return true }
        return first.kind == .openApp || first.kind == .home
    }

    var body: some View {
        List {
            Section {
                TextField("腳本名稱", text: $draft.name)
                Toggle("一直重複，直到手動停止", isOn: Binding(
                    get: { draft.loops == 0 },
                    set: { draft.loops = $0 ? 0 : 1 }
                ))
                if draft.loops != 0 {
                    Stepper("執行 \(draft.loops) 次", value: $draft.loops, in: 1...999)
                }
            }

            Section {
                Button {
                    recording = true
                } label: {
                    Label(draft.steps.isEmpty ? "開始錄製" : "接著錄製", systemImage: "record.circle")
                }
                .disabled(!ready)
                Button {
                    Task {
                        store.save(draft)
                        await controller.run(draft)
                    }
                } label: {
                    Label("執行", systemImage: "play.fill")
                }
                .disabled(!ready || draft.steps.isEmpty || controller.progress?.isActive == true)
            } footer: {
                if !ready {
                    Text("回上一頁完成「準備」後才能錄製和執行。")
                } else if !startsInAnApp {
                    Text("第一步不是打開 App，腳本會從目前的畫面開始點。")
                } else {
                    Text("手機一鎖定腳本就會停。腳本要跑很久的話，到「設定 → 螢幕顯示與亮度 → 自動鎖定」改成永不。")
                }
            }

            Section {
                ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, step in
                    Button {
                        editing = step
                    } label: {
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 24, alignment: .trailing)
                            Image(systemName: step.symbol)
                                .foregroundColor(.accentColor)
                                .frame(width: 24)
                            Text(step.title)
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                .onDelete { draft.steps.remove(atOffsets: $0) }
                .onMove { draft.steps.move(fromOffsets: $0, toOffset: $1) }
                addMenu
            } header: {
                HStack {
                    Text("步驟")
                    Spacer()
                    if !draft.steps.isEmpty { EditButton().font(.footnote) }
                }
            }

            Section {
                Button(linkCopied ? "已複製" : "複製一鍵執行連結") {
                    store.save(draft)
                    UIPasteboard.general.string = ScriptController.runLink(for: draft.id)
                    linkCopied = true
                }
            } footer: {
                Text("到「捷徑」App 新增「打開 URL」，貼上連結，再把捷徑加到主畫面，就能從主畫面一鍵執行。")
            }

            Section {
                Button("刪除腳本", role: .destructive) {
                    store.delete(id: draft.id)
                    dismiss()
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: draft) { store.save($0) }
        .fullScreenCover(isPresented: $recording) {
            RecorderView(script: $draft)
                .environmentObject(admin)
        }
        .sheet(item: $editing) { step in
            StepEditView(step: step) { changed in
                if let index = draft.steps.firstIndex(where: { $0.id == changed.id }) {
                    draft.steps[index] = changed
                }
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button("等幾秒") { add(ScriptStep(kind: .wait, duration: 2)) }
            Button("等畫面出現文字") { add(ScriptStep(kind: .waitText, text: "", timeout: 30)) }
            Button("點畫面上的文字") { add(ScriptStep(kind: .tapText, text: "", timeout: 30)) }
            Button("看到文字才做下面幾步") { add(ScriptStep(kind: .ifText, text: "", timeout: 3, skip: 1)) }
            Button("回主畫面") { draft.steps.append(ScriptStep(kind: .home)) }
        } label: {
            Label("手動加一步", systemImage: "plus")
        }
    }

    private func add(_ step: ScriptStep) {
        draft.steps.append(step)
        editing = step
    }
}

/// Change the parts of a step that make sense to change by hand.
struct StepEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var step: ScriptStep
    let onDone: (ScriptStep) -> Void

    init(step: ScriptStep, onDone: @escaping (ScriptStep) -> Void) {
        _step = State(initialValue: step)
        self.onDone = onDone
    }

    private var usesText: Bool {
        [.type, .waitText, .tapText, .ifText].contains(step.kind)
    }

    private var usesTimeout: Bool {
        [.waitText, .tapText, .ifText].contains(step.kind)
    }

    private var usesDuration: Bool {
        [.wait, .longPress, .swipe].contains(step.kind)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(step.title, systemImage: step.symbol)
                }
                if usesText {
                    Section("文字") {
                        TextField("要找或要輸入的文字", text: Binding(
                            get: { step.text ?? "" },
                            set: { step.text = $0 }
                        ))
                    }
                }
                if step.kind == .openApp {
                    Section {
                        Toggle("每次都從頭打開", isOn: flag(\.restart))
                    } footer: {
                        Text("先關掉這個 App 再打開，腳本才會從同一個畫面開始。")
                    }
                }
                if step.kind == .type {
                    Section {
                        Toggle("先清空輸入框", isOn: flag(\.clear))
                        Toggle("輸入後按送出", isOn: flag(\.submit))
                    }
                }
                if usesDuration {
                    Section("秒數") {
                        Stepper("\(ScriptStep.number(step.duration ?? 1)) 秒",
                                value: Binding(get: { step.duration ?? 1 }, set: { step.duration = $0 }),
                                in: 0.1...3600, step: step.kind == .wait ? 1 : 0.1)
                    }
                }
                if usesTimeout {
                    Section("最多等幾秒") {
                        Stepper("\(ScriptStep.number(step.timeout ?? 30)) 秒",
                                value: Binding(get: { step.timeout ?? 30 }, set: { step.timeout = $0 }),
                                in: 0...600, step: 1)
                    }
                }
                if step.kind == .ifText {
                    Section {
                        Toggle("改成「沒看到」才做", isOn: flag(\.negate))
                        Stepper("影響下面 \(step.skip ?? 1) 步",
                                value: Binding(get: { step.skip ?? 1 }, set: { step.skip = $0 }),
                                in: 1...99)
                    }
                }
            }
            .navigationTitle("編輯步驟")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onDone(step)
                        dismiss()
                    }
                }
            }
        }
    }

    private func flag(_ key: WritableKeyPath<ScriptStep, Bool?>) -> Binding<Bool> {
        Binding(get: { step[keyPath: key] == true }, set: { step[keyPath: key] = $0 })
    }
}
