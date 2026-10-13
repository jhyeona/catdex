import AppKit
import SwiftUI
import CatdexCore
import UniformTypeIdentifiers

private func projectName(_ path: String) -> String { path.isEmpty ? "프로젝트 없음" : URL(fileURLWithPath: path).lastPathComponent }
private func timeLabel(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

struct PlannerRootView: View {
    @ObservedObject var model: PlannerModel
    var quickAdd: () -> Void
    @State private var showSettings = false
    @State private var showMemo = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("🐱 내 할 일").font(.title2.bold())
                Spacer()
                TextField("할 일 검색", text: $model.search).frame(width: 180)
                if !model.showTimeline { Button("주간 달력") { model.section = "week"; model.showTimeline = true } }
                Button("+ 할 일", action: quickAdd).buttonStyle(.borderedProminent).keyboardShortcut("n", modifiers: .command)
                Menu("더보기") {
                    Button("메모 남기기") { showMemo = true }
                    Button("기록함 열기") { model.section = "inbox"; model.showTimeline = false }
                    Divider()
                    Button("설정") { showSettings = true }
                }.fixedSize()
            }.padding()
            if let error = model.error {
                HStack { Image(systemName: "exclamationmark.triangle"); Text(error).textSelection(.enabled); Spacer(); Button("닫기") { model.error = nil } }
                    .padding(10).background(Color.orange.opacity(0.13))
            }
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 150)
                Divider()
                if !model.showTimeline {
                    itemList.frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
                    Divider()
                }
                if model.showTimeline {
                    PlannerTimelineView(model: model, quickAdd: quickAdd)
                } else if let id = model.selectedTaskID, let task = model.snapshot.tasks.first(where: { $0.id == id }) {
                    TaskEditorView(model: model, task: task).id(task.id)
                } else if let id = model.selectedRecordID, let record = model.snapshot.records.first(where: { $0.id == id }) {
                    RecordEditorView(model: model, record: record).id(record.id)
                } else {
                    VStack(spacing: 12) { Image(systemName: "text.alignleft").font(.largeTitle); Text("기록이나 할 일을 선택하세요") }
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .sheet(isPresented: $showSettings) { PlannerSettingsView(model: model) }
        .sheet(isPresented: $showMemo) {
            VStack(alignment: .trailing) {
                Button("닫기") { showMemo = false }.padding([.top, .trailing])
                QuickCaptureView(model: model, initialProject: "") {
                    showMemo = false; model.section = "inbox"; model.showTimeline = false
                }
            }.frame(width: 520)
        }
        .sheet(isPresented: Binding(get: { model.proposal != nil }, set: { if !$0 { model.proposal = nil } })) { ProposalView(model: model) }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            nav("주간 달력", "week", "calendar")
            nav("전체 할 일", "all", "checklist")
            nav("완료한 일", "done", "checkmark.circle")
            Divider().padding(.vertical, 8)
            DisclosureGroup("분류 더보기") {
                nav("오늘", "today", "sun.max")
                nav("대기 중", "waiting", "hourglass")
                nav("기록함", "inbox", "tray")
                Picker("프로젝트", selection: $model.projectFilter) {
                    Text("모두").tag("")
                    ForEach(model.projects, id: \.self) { Text(projectName($0)).tag($0) }
                }
            }.font(.caption)
            if !model.projectFilter.isEmpty {
                Button("프로젝트 필터 해제") { model.projectFilter = "" }.font(.caption)
            }
            Spacer()
        }.padding(12).frame(maxHeight: .infinity).background(Color(nsColor: .controlBackgroundColor))
    }
    private func nav(_ title: String, _ value: String, _ icon: String) -> some View {
        Button {
            model.section = value
            model.showTimeline = value == "week"
        } label: {
            HStack { Image(systemName: icon).frame(width: 18); Text(title); Spacer() }
                .padding(8).background(model.section == value ? Color.accentColor.opacity(0.15) : .clear).cornerRadius(7)
        }.buttonStyle(.plain)
    }
    private func openTask(_ task: PlannerTask) {
        model.selectedTaskID = task.id; model.selectedRecordID = nil; model.showTimeline = false
    }
    private var filteredTasks: [PlannerTask] {
        model.snapshot.tasks.filter { task in
            let scope: Bool
            switch model.section {
            case "week":
                let week = PlannerWeek(containing: model.day)
                scope = task.state != .done && (
                    [task.plannedDay, task.dueAt, task.reviewAt].compactMap { $0 }.contains(where: week.contains) ||
                    model.snapshot.blocks.contains { $0.taskID == task.id && week.intersects($0) })
            case "today": scope = PlannerScheduler.isToday(task, day: Date())
            case "upcoming": scope = task.state != .done && (task.plannedDay != nil || task.dueAt != nil || model.snapshot.blocks.contains { $0.taskID == task.id })
            case "waiting": scope = task.state == .waiting
            case "done": scope = task.state == .done
            default: scope = task.state != .done
            }
            let record = model.snapshot.records.first { $0.id == task.recordID }
            return scope && (model.projectFilter.isEmpty || task.project == model.projectFilter) &&
                (model.search.isEmpty || [task.title, task.pauseNote, task.note, record?.text ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(model.search))
        }.sorted(by: PlannerTask.precedes)
    }
    private var itemList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if model.section == "inbox" {
                    Text("기록을 열어 할 일 후보를 확인하세요").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.snapshot.records.filter {
                        (model.projectFilter.isEmpty || $0.project == model.projectFilter) &&
                        (model.search.isEmpty || ($0.text + " " + $0.context).localizedCaseInsensitiveContains(model.search))
                    }.sorted { $0.createdAt > $1.createdAt }) { record in
                        Button {
                            model.selectedRecordID = record.id; model.selectedTaskID = nil; model.showTimeline = false
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(record.text).lineLimit(3).multilineTextAlignment(.leading)
                                HStack { Text(record.resolved ? "보관됨" : "확인 대기"); Spacer(); Text(projectName(record.project)) }.font(.caption).foregroundStyle(.secondary)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.accentColor.opacity(model.selectedRecordID == record.id ? 0.13 : 0.04)).cornerRadius(8)
                        }.buttonStyle(.plain)
                    }
                    if model.snapshot.records.isEmpty { Text("개발하다 떠오른 일을 기록해 보세요.").padding(.top, 20).foregroundStyle(.secondary) }
                } else {
                    Text("\(filteredTasks.count)개 할 일").font(.caption).foregroundStyle(.secondary)
                    Text("드래그하거나 ↑↓로 순서 변경").font(.caption2).foregroundStyle(.secondary)
                    ForEach(filteredTasks) { task in
                        HStack(alignment: .top, spacing: 8) {
                            Button { model.complete(task) } label: { Image(systemName: task.state == .done ? "checkmark.circle.fill" : "circle") }.buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 5) {
                                Text((task.pinned ? "★ " : "") + task.title).strikethrough(task.state == .done).multilineTextAlignment(.leading)
                                Text(task.plannedDay?.formatted(date: .abbreviated, time: .omitted) ?? "날짜 미정").font(.caption).foregroundStyle(.secondary)
                                if let due = task.dueAt { Text("마감 \(due.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.orange) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                // A native Button consumes drags over its label before the card sees them.
                                .onTapGesture { openTask(task) }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { openTask(task) }
                            PlannerOrderButtons(model: model, task: task, tasks: filteredTasks, vertical: true)
                        }.padding(12).background(Color.accentColor.opacity(model.selectedTaskID == task.id ? 0.13 : 0.04)).cornerRadius(8)
                            .onDrag { NSItemProvider(object: task.id as NSString) }
                            .modifier(PlannerTaskDropTarget(model: model, targetID: task.id))
                            .contextMenu {
                                Button("오늘 하기") { model.update(task) { $0.plannedDay = Date() } }
                                Button("내일 하기") { model.tomorrow(task) }
                                Button(task.pinned ? "핵심 고정 해제" : "핵심 3개에 고정") { model.update(task) { $0.pinned.toggle() } }
                                Button("목록 맨 위로") { model.moveTask(task.id, relativeTo: filteredTasks.first?.id) }
                            }
                    }
                    if !filteredTasks.isEmpty {
                        Text("맨 아래로 이동").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .modifier(PlannerTaskDropTarget(model: model, targetID: filteredTasks.last?.id, alwaysAfter: true))
                    }
                    if filteredTasks.isEmpty { Text("이 목록에 할 일이 없습니다.").padding(.top, 20).foregroundStyle(.secondary) }
                }
            }.padding(12)
        }
    }
}

/// Visible controls keep reordering discoverable and usable without dragging.
struct PlannerOrderButtons: View {
    @ObservedObject var model: PlannerModel
    let task: PlannerTask
    let tasks: [PlannerTask]
    var vertical = false
    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 6))
        layout {
            if !vertical { Text("순서").font(.caption2).foregroundStyle(.secondary) }
            moveButton(-1, symbol: "arrow.up", title: "위로 이동")
            moveButton(1, symbol: "arrow.down", title: "아래로 이동")
        }.controlSize(.small)
    }
    private func moveButton(_ step: Int, symbol: String, title: String) -> some View {
        Button { model.moveTask(task, step: step, in: tasks) } label: {
            Image(systemName: symbol).font(.caption).frame(width: 16, height: 16)
        }.buttonStyle(.bordered)
            .disabled(step < 0 ? tasks.first?.id == task.id : tasks.last?.id == task.id)
            .help(title).accessibilityLabel("\(task.title) \(title)")
    }
}

struct PlannerTaskDropTarget: ViewModifier {
    @ObservedObject var model: PlannerModel
    var targetID: String?
    var day: Date?
    var alwaysAfter = false
    @State private var height: CGFloat = 60
    @State private var dropAfter: Bool?
    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geometry in
                Color.clear.onAppear { height = geometry.size.height }
                    .onChange(of: geometry.size.height) { height = $0 }
            })
            .overlay(alignment: dropAfter == true ? .bottom : .top) {
                if dropAfter != nil {
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(height: 3)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.text], delegate: PlannerTaskDropDelegate(
                model: model, targetID: targetID, day: day, height: height,
                alwaysAfter: alwaysAfter, dropAfter: $dropAfter
            ))
    }
}

struct PlannerTaskDropDelegate: DropDelegate {
    let model: PlannerModel
    let targetID: String?
    let day: Date?
    let height: CGFloat
    let alwaysAfter: Bool
    @Binding var dropAfter: Bool?
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }
    func dropEntered(info: DropInfo) { dropAfter = alwaysAfter || info.location.y > height / 2 }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropAfter = alwaysAfter || info.location.y > height / 2
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { dropAfter = nil }
    func performDrop(info: DropInfo) -> Bool {
        let after = alwaysAfter || info.location.y > height / 2
        dropAfter = nil
        guard let provider = info.itemProviders(for: [.text]).first,
              provider.canLoadObject(ofClass: String.self) else { return false }
        _ = provider.loadObject(ofClass: String.self) { value, _ in
            guard let value else { return }
            Task { @MainActor in model.moveTask(value, relativeTo: targetID, after: after, toDay: day) }
        }
        return true
    }
}

struct OptionalPlannerDate: View {
    let title: String
    @Binding var value: Date?
    var time = false
    var body: some View {
        HStack {
            Toggle(title, isOn: Binding(get: { value != nil }, set: { value = $0 ? Date() : nil })).toggleStyle(.checkbox)
            Spacer()
            if value != nil {
                DatePicker("", selection: Binding(get: { value ?? Date() }, set: { value = $0 }), displayedComponents: time ? [.date, .hourAndMinute] : [.date]).labelsHidden()
            }
        }
    }
}

struct CandidateFields: View {
    @Binding var candidate: TaskCandidate
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("할 일 제목", text: $candidate.title)
            OptionalPlannerDate(title: "작업할 날짜", value: $candidate.plannedDay)
            OptionalPlannerDate(title: "마감", value: $candidate.dueAt, time: true)
            HStack {
                Text("예상 소요시간")
                TextField("30분 가정", value: $candidate.estimatedMinutes, format: .number).frame(width: 70)
                Text("분").foregroundStyle(.secondary)
            }
            HStack {
                Text("희망 시간대")
                TextField("시작", value: $candidate.preferredStartHour, format: .number).frame(width: 50)
                Text("~")
                TextField("종료", value: $candidate.preferredEndHour, format: .number).frame(width: 50)
                Text("시 (24시간)").font(.caption).foregroundStyle(.secondary)
            }
            if !candidate.note.isEmpty { Text(candidate.note).font(.caption).foregroundStyle(.orange) }
        }
    }
}

struct RecordEditorView: View {
    @ObservedObject var model: PlannerModel
    let record: PlannerRecord
    @State private var candidates: [TaskCandidate]
    @State private var selected: Set<String>
    init(model: PlannerModel, record: PlannerRecord) {
        self.model = model; self.record = record
        _candidates = State(initialValue: record.candidates)
        _selected = State(initialValue: Set(record.candidates.map(\.id)))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(record.resolved ? "보관된 기록" : "기록 → 할 일 후보").font(.title2.bold())
                Text(record.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Text("\(projectName(record.project)) · \(record.createdAt.formatted())").font(.caption).foregroundStyle(.secondary)
                if !record.context.isEmpty { DisclosureGroup("저장된 대화 맥락") { Text(record.context).textSelection(.enabled) } }
                if !record.resolved {
                    ForEach($candidates) { $candidate in
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("할 일로 등록", isOn: Binding(get: { selected.contains(candidate.id) }, set: { if $0 { selected.insert(candidate.id) } else { selected.remove(candidate.id) } }))
                            CandidateFields(candidate: $candidate)
                        }.padding().background(Color(nsColor: .controlBackgroundColor)).cornerRadius(10)
                    }
                    Button("+ 후보 직접 추가") { let candidate = TaskCandidate(title: ""); candidates.append(candidate); selected.insert(candidate.id) }
                    HStack {
                        Button("메모로 보관") { model.perform { try model.store.resolve(record: record, selected: []) } }
                        Spacer()
                        Button("선택한 \(selected.count)개 등록") {
                            model.perform { try model.store.resolve(record: record, selected: candidates.filter { selected.contains($0.id) }) }
                        }.buttonStyle(.borderedProminent).disabled(selected.isEmpty)
                    }
                } else { Text("원문이 보존되었습니다. 등록한 작업은 전체 작업에서 수정할 수 있습니다.").foregroundStyle(.secondary) }
            }.padding(22)
        }.frame(maxWidth: .infinity)
    }
}

struct TaskEditorView: View {
    @ObservedObject var model: PlannerModel
    let task: PlannerTask
    @State private var draft: PlannerTask
    @State private var checklistTitle = ""
    @State private var lastSaved: PlannerTask?
    @State private var lastSeen: PlannerTask
    @State private var changedElsewhere = false
    init(model: PlannerModel, task: PlannerTask) {
        self.model = model; self.task = task
        _draft = State(initialValue: task); _lastSeen = State(initialValue: task)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if changedElsewhere {
                    Text("다른 곳에서 작업이 변경되었습니다. 되돌리기를 눌러 최신 내용을 불러오세요.").font(.caption).foregroundStyle(.orange)
                }
                TextField("할 일 제목", text: $draft.title).font(.title2.bold())
                DatePicker("날짜", selection: Binding(get: { draft.plannedDay ?? model.day }, set: { draft.plannedDay = $0 }), displayedComponents: [.date])
                Toggle("완료", isOn: Binding(get: { draft.state == .done }, set: { draft.state = $0 ? .done : .todo }))
                Text("메모").font(.headline)
                TextEditor(text: $draft.note).frame(height: 80).border(Color.gray.opacity(0.2))
                DisclosureGroup("세부 설정") {
                Text(projectName(draft.project)).font(.caption).foregroundStyle(.secondary)
                Picker("상태", selection: $draft.state) { ForEach(WorkState.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                HStack {
                    Picker("우선순위", selection: $draft.priority) { Text("낮음").tag(0); Text("보통").tag(1); Text("높음").tag(2) }
                    Toggle("핵심 3개", isOn: $draft.pinned)
                }
                OptionalPlannerDate(title: "마감", value: $draft.dueAt, time: true)
                if draft.state == .waiting { OptionalPlannerDate(title: "다시 확인할 날짜", value: $draft.reviewAt) }
                HStack {
                    Text("예상시간")
                    TextField("30분 가정", value: $draft.estimatedMinutes, format: .number).frame(width: 70)
                    Text("분")
                    Spacer()
                    TextField("희망 시작", value: $draft.preferredStartHour, format: .number).frame(width: 65)
                    Text("~")
                    TextField("종료", value: $draft.preferredEndHour, format: .number).frame(width: 50)
                    Text("시")
                }
                Text("중단 메모 · 다음에는 여기부터").font(.headline)
                TextEditor(text: $draft.pauseNote).frame(height: 75).border(Color.gray.opacity(0.2))
                Text("체크리스트").font(.headline)
                ForEach($draft.checklist) { $item in
                    HStack { Toggle("", isOn: $item.done).labelsHidden(); TextField("항목", text: $item.title); Button { draft.checklist.removeAll { $0.id == item.id } } label: { Image(systemName: "minus.circle") } }
                }
                HStack { TextField("체크리스트 추가", text: $checklistTitle); Button("추가") { if !checklistTitle.isEmpty { draft.checklist.append(ChecklistItem(title: checklistTitle)); checklistTitle = "" } } }
                }
                HStack {
                    Button("되돌리기") { draft = task; changedElsewhere = false }
                    Spacer()
                    Button(lastSaved == draft ? "저장됨 ✓" : "변경 저장") { if model.perform({ try model.store.saveTask(draft) }), let saved = model.snapshot.tasks.first(where: { $0.id == draft.id }) { draft = saved; lastSaved = saved; changedElsewhere = false } }.buttonStyle(.borderedProminent)
                }
                DisclosureGroup("원본 기록 · 프로젝트") {
                HStack {
                    Button("프로젝트 열기") { NSWorkspace.shared.open(URL(fileURLWithPath: task.project)) }.disabled(task.project.isEmpty)
                    Button("이어가기 문맥 복사") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.context(for: task), forType: .string) }
                }
                if let record = model.snapshot.records.first(where: { $0.id == task.recordID }) {
                    Text(record.text).textSelection(.enabled)
                    if !record.context.isEmpty { Text(record.context).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let session = record.sessionID { Text("세션: \(session)").font(.caption).textSelection(.enabled) }
                }
                }
            }.padding(22)
        }.frame(maxWidth: .infinity)
            .onChange(of: task) { updated in
                if draft == lastSeen || draft == updated {
                    draft = updated; changedElsewhere = false
                } else { changedElsewhere = true }
                lastSeen = updated
            }
    }
}

struct QuickTaskView: View {
    @ObservedObject var model: PlannerModel
    let initialDay: Date
    var project = ""
    var onCancel: () -> Void
    var onSave: () -> Void
    @State private var title = ""
    @State private var day = Date()
    @State private var requestID = UUID().uuidString
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("할 일 추가").font(.title2.bold())
            TextField("무엇을 해야 하나요?", text: $title).textFieldStyle(.roundedBorder).focused($focused).onSubmit(save)
            HStack {
                DatePicker("날짜", selection: $day, displayedComponents: [.date])
                Button("오늘") { day = Date() }
                Button("내일") { day = Calendar.current.date(byAdding: .day, value: 1, to: Date())! }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("취소", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("추가", action: save).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).onAppear { day = initialDay; focused = true }
    }
    private func save() {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if model.perform({ try model.store.addTask(title: title, day: day, project: project, requestID: requestID) }) {
            model.day = day; title = ""; requestID = UUID().uuidString; onSave()
        }
    }
}

struct QuickCaptureView: View {
    @ObservedObject var model: PlannerModel
    var initialProject: String
    var onSave: () -> Void
    @State private var text = ""
    @State private var project = ""
    @State private var requestID = UUID().uuidString
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("생각을 기록하고, 할 일은 확인 후 등록하세요.").font(.headline)
            TextEditor(text: $text).frame(minHeight: 100).focused($focused).border(Color.gray.opacity(0.2))
            HStack {
                TextField("프로젝트 폴더 (선택)", text: $project)
                Menu("선택") {
                    ForEach(model.projects, id: \.self) { path in Button(projectName(path)) { project = path } }
                    Button("폴더 찾기…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                        if panel.runModal() == .OK { project = panel.url?.path ?? "" }
                    }
                }
            }
            HStack {
                Text("예: /기록 내일 오전 로그인 버그 확인 40분 예상").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("기록 저장") {
                    var saved: PlannerRecord?
                    if model.perform({ saved = try model.store.capture(CaptureRequest(requestID: requestID, text: text, project: project)) }) {
                        model.selectedRecordID = saved?.id; model.selectedTaskID = nil
                        text = ""; requestID = UUID().uuidString; onSave()
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(18).onAppear { project = initialProject; focused = true }
    }
}

struct PlannerTimelineView: View {
    @ObservedObject var model: PlannerModel
    var quickAdd: () -> Void
    @State private var editingBlock: PlannerBlock?
    @State private var editingTask: PlannerTask?
    @State private var showHours = false
    private var week: PlannerWeek { PlannerWeek(containing: model.day) }
    private var blocks: [PlannerBlock] {
        model.snapshot.blocks.filter { week.intersects($0) }.sorted { $0.start < $1.start }
    }
    private let weekdays = ["월", "화", "수", "목", "금", "토", "일"]

    private func blocks(on day: Date, hour: Int) -> [PlannerBlock] {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        return blocks.filter {
            $0.start < end && $0.end > day &&
            Calendar.current.component(.hour, from: max($0.start, day)) == hour
        }
    }
    private func moveWeek(_ offset: Int) {
        model.day = Calendar.current.date(byAdding: .day, value: offset * 7, to: model.day)!
    }
    private var weekTitle: String {
        let format = Date.FormatStyle.dateTime.year().month().day()
        return "\(week.days[0].formatted(format)) – \(week.days[6].formatted(.dateTime.month().day()))"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { moveWeek(-1) } label: { Image(systemName: "chevron.left") }.help("이전 주").accessibilityLabel("이전 주")
                Text(weekTitle).font(.headline).lineLimit(1)
                Button { moveWeek(1) } label: { Image(systemName: "chevron.right") }.help("다음 주").accessibilityLabel("다음 주")
                Spacer(minLength: 8)
                Button("이번 주") { model.day = Date() }
            }
            HStack {
                Text("완료는 체크 · 순서는 드래그 또는 ↑↓").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu("일정 도구") {
                    Toggle("시간표 보기", isOn: $showHours)
                    Divider()
                    Button("선택한 날짜에 시간 추천") { model.recommend() }
                    Button("밀린 일정 다시 배치") { model.recommend(reschedule: true) }
                    Button("회의 · 고정 일정 추가") {
                        let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: model.day)!
                        editingBlock = PlannerBlock(title: "", start: start, end: start.addingTimeInterval(3600))
                    }
                }.fixedSize().controlSize(.small)
            }
            GeometryReader { geometry in
                let dayWidth = max(1, (geometry.size.width - (showHours ? 58 : 0)) / 7)
                VStack(spacing: 10) {
                    dayHeaders(width: dayWidth)
                    if showHours {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(0..<24, id: \.self) { hour in
                                    hourRow(hour, width: dayWidth).id(hour)
                                }
                            }
                        }.onAppear { proxy.scrollTo(model.snapshot.preferences.startHour, anchor: .top) }
                    }
                    } else {
                        weekBoard(width: dayWidth)
                    }
                }
            }
        }.padding(14).frame(maxWidth: .infinity)
            .sheet(item: $editingBlock) { block in BlockEditorView(model: model, block: block) }
            .sheet(item: $editingTask) { task in
                VStack(alignment: .trailing, spacing: 0) {
                    Button("닫기") { editingTask = nil }.padding()
                    if let current = model.snapshot.tasks.first(where: { $0.id == task.id }) {
                        TaskEditorView(model: model, task: current)
                    }
                }.frame(width: 520, height: 570)
            }
    }
    private func dayHeaders(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if showHours { Text("시간").font(.caption).foregroundStyle(.secondary).frame(width: 44) }
            ForEach(Array(week.days.enumerated()), id: \.element) { index, day in
                Button { model.day = day } label: {
                    VStack(spacing: 4) {
                        Text(weekdays[index]).font(.caption).foregroundStyle(index >= 5 ? .secondary : .primary)
                        Text(day.formatted(.dateTime.month().day())).font(.callout.bold())
                        Text(Calendar.current.isDateInToday(day) ? "오늘" : " ").font(.caption2).foregroundStyle(Color.accentColor)
                    }.frame(width: width).padding(.vertical, 7)
                        .background(Calendar.current.isDate(day, inSameDayAs: model.day) ? Color.accentColor.opacity(0.14) : .clear)
                        .cornerRadius(7)
                }.buttonStyle(.plain)
                    .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted))\(Calendar.current.isDateInToday(day) ? ", 오늘" : "")")
                    .accessibilityValue(Calendar.current.isDate(day, inSameDayAs: model.day) ? "선택됨" : "")
            }
        }.padding(.trailing, showHours ? 14 : 0)
    }
    private func dayTasks(_ day: Date) -> [PlannerTask] {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        return model.snapshot.tasks.filter { task in
            task.state != .done && (model.projectFilter.isEmpty || task.project == model.projectFilter) &&
            (model.search.isEmpty || (task.title + " " + task.note).localizedCaseInsensitiveContains(model.search)) &&
            ((task.plannedDay.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false) ||
             blocks.contains { $0.taskID == task.id && $0.start < end && $0.end > day })
        }.sorted(by: PlannerTask.precedes)
    }
    private func weekBoard(width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(week.days, id: \.self) { day in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(dayTasks(day)) { task in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top, spacing: 6) {
                                    Button { model.complete(task) } label: { Image(systemName: "circle").font(.body) }
                                        .buttonStyle(.plain).help("완료").accessibilityLabel("\(task.title) 완료")
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(task.title).font(.callout).multilineTextAlignment(.leading)
                                        if let block = blocks.first(where: { $0.taskID == task.id && Calendar.current.isDate($0.start, inSameDayAs: day) }) {
                                            Text(timeLabel(block.start)).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                        .onTapGesture { editingTask = task }
                                        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
                                        .accessibilityAction { editingTask = task }
                                }
                                HStack { Spacer(minLength: 0); PlannerOrderButtons(model: model, task: task, tasks: dayTasks(day)) }
                            }.padding(10).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(8)
                                .onDrag { NSItemProvider(object: task.id as NSString) }
                                .modifier(PlannerTaskDropTarget(model: model, targetID: task.id, day: day))
                        }
                        ForEach(blocks.filter { $0.taskID == nil && $0.start < Calendar.current.date(byAdding: .day, value: 1, to: day)! && $0.end > day }) { block in
                            Button { editingBlock = block } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(block.title).font(.callout)
                                    Text(blockTime(block, day: day)).font(.caption).foregroundStyle(.secondary)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.orange.opacity(0.1)).cornerRadius(8)
                            }.buttonStyle(.plain)
                        }
                        Button { model.day = day; quickAdd() } label: {
                            Label("추가", systemImage: "plus").font(.callout).frame(maxWidth: .infinity).padding(.vertical, 8)
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("\(day.formatted(date: .abbreviated, time: .omitted)) 할 일 추가")
                    }.padding(6)
                }.frame(width: width).frame(maxHeight: .infinity)
                    .background(Calendar.current.isDateInToday(day) ? Color.accentColor.opacity(0.04) : Color.secondary.opacity(0.025))
                    .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.12)).frame(width: 0.5) }
                    .modifier(PlannerTaskDropTarget(model: model, targetID: dayTasks(day).last?.id, day: day, alwaysAfter: true))
            }
        }
    }
    private func hourRow(_ hour: Int, width: CGFloat) -> some View {
        let count = week.days.map { blocks(on: $0, hour: hour).count }.max() ?? 0
        let height = CGFloat(max(56, count * 72 + 8))
        return HStack(alignment: .top, spacing: 0) {
            Text(String(format: "%02d:00", hour)).font(.caption.monospacedDigit())
                .foregroundStyle(.secondary).frame(width: 44, alignment: .leading).padding(.top, 5)
            ForEach(week.days, id: \.self) { day in
                hourCell(day: day, hour: hour, width: width, height: height)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func hourCell(day: Date, hour: Int, width: CGFloat, height: CGFloat) -> some View {
        let preferences = model.snapshot.preferences
        let lunch = preferences.lunchEnabled && hour >= preferences.lunchStartHour && hour < preferences.lunchEndHour
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(blocks(on: day, hour: hour)) { block in
                Button { model.day = day; editingBlock = block } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(block.title).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                        Text(blockTime(block, day: day)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    }.padding(5).frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64, alignment: .topLeading)
                        .background((block.taskID == nil ? Color.orange : Color.accentColor).opacity(0.13))
                        .overlay(alignment: .leading) { Rectangle().fill(block.taskID == nil ? Color.orange : Color.accentColor).frame(width: 2) }
                        .cornerRadius(4)
                }.buttonStyle(.plain).help("\(block.title) · \(blockTime(block, day: day))")
            }
            if lunch && blocks(on: day, hour: hour).isEmpty {
                Text("점심").font(.caption2).foregroundStyle(.tertiary).padding(4)
            }
            Spacer(minLength: 0)
        }.padding(3).frame(width: width, height: height, alignment: .topLeading)
            .background(lunch ? Color.secondary.opacity(0.07) : (Calendar.current.isDateInToday(day) ? Color.accentColor.opacity(0.025) : .clear))
            .overlay(alignment: .top) { Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 0.5) }
            .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 0.5) }
            .contentShape(Rectangle())
            .onDrop(of: [.text], isTargeted: nil) { providers in
                guard let provider = providers.first, provider.canLoadObject(ofClass: String.self),
                      let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) else { return false }
                _ = provider.loadObject(ofClass: String.self) { value, _ in
                    guard let value else { return }
                    Task { @MainActor in model.day = day; model.place(taskID: value, at: date) }
                }
                return true
            }
    }
    private func blockTime(_ block: PlannerBlock, day: Date) -> String {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let startLabel = block.start < day ? "이전 날부터" : timeLabel(block.start)
        let endLabel = block.end >= end ? "24:00" : timeLabel(block.end)
        return "\(startLabel)–\(endLabel)"
    }
}

struct BlockEditorView: View {
    @ObservedObject var model: PlannerModel
    let block: PlannerBlock
    @State private var draft: PlannerBlock
    @Environment(\.dismiss) private var dismiss
    init(model: PlannerModel, block: PlannerBlock) { self.model = model; self.block = block; _draft = State(initialValue: block) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(block.taskID == nil ? "고정 일정" : "작업 일정 이동").font(.title2.bold())
            TextField("일정 제목", text: $draft.title)
            DatePicker("시작", selection: $draft.start)
            DatePicker("종료", selection: $draft.end)
            if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("취소") { dismiss() }
                if model.snapshot.blocks.contains(where: { $0.id == block.id }) {
                    Button("일정 삭제") { if model.perform({ try model.store.removeBlock(block) }) { dismiss() } }
                }
                Spacer()
                Button("저장") {
                    let replacing = model.snapshot.blocks.contains(where: { $0.id == block.id }) ? [block] : []
                    if model.perform({ try model.store.addBlocks([draft], replacing: replacing) }) { dismiss() }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 440)
    }
}

struct ProposalView: View {
    @ObservedObject var model: PlannerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("시간 배치 추천안").font(.title2.bold())
            Text("확정 전에는 기존 일정이 바뀌지 않습니다. 시작 시간을 수정하거나 제외할 수 있습니다.").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let proposal = model.proposal {
                        ForEach(proposal.blocks) { block in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(block.title).font(.headline)
                                    Spacer()
                                    Button("제외") { model.proposal?.blocks.removeAll { $0.id == block.id } }
                                }
                                DatePicker("시작", selection: Binding(get: { model.proposal?.blocks.first { $0.id == block.id }?.start ?? block.start }, set: { date in
                                    guard let index = model.proposal?.blocks.firstIndex(where: { $0.id == block.id }) else { return }
                                    let duration = block.end.timeIntervalSince(block.start)
                                    model.proposal?.blocks[index].start = date
                                    model.proposal?.blocks[index].end = date.addingTimeInterval(duration)
                                }))
                                Text("\(Int(block.end.timeIntervalSince(block.start) / 60))분\(proposal.assumedDurationTaskIDs.contains(block.taskID ?? "") ? " · 예상시간 미입력, 30분 가정" : "")").font(.caption).foregroundStyle(.secondary)
                            }.padding(12).background(Color.accentColor.opacity(0.06)).cornerRadius(8)
                        }
                        if proposal.blocks.isEmpty { Text("배치할 작업이 없습니다.").foregroundStyle(.secondary) }
                        if !proposal.unplaced.isEmpty {
                            Divider(); Text("배치하지 못한 작업").font(.headline)
                            ForEach(proposal.unplaced.keys.sorted(), id: \.self) { id in
                                Text("• \(model.snapshot.tasks.first { $0.id == id }?.title ?? id)\n  \(proposal.unplaced[id] ?? "")").font(.callout)
                            }
                        }
                    }
                }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("취소") { model.proposal = nil }
                Button("다시 계산") { model.recommend(reschedule: !(model.proposal?.replacing.isEmpty ?? true)) }
                Spacer()
                Button("일정 확정") { model.confirmProposal() }.buttonStyle(.borderedProminent).disabled(model.proposal?.blocks.isEmpty ?? true)
            }
        }.padding(24).frame(width: 570, height: 550)
    }
}

struct PlannerSettingsView: View {
    @ObservedObject var model: PlannerModel
    @State private var draft: PlannerPreferences
    @Environment(\.dismiss) private var dismiss
    init(model: PlannerModel) { self.model = model; _draft = State(initialValue: model.snapshot.preferences) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("플래너 설정").font(.title2.bold())
            HStack {
                Stepper("업무 시작 \(draft.startHour)시", value: $draft.startHour, in: 0...23)
                Stepper("종료 \(draft.endHour)시", value: $draft.endHour, in: 1...24)
            }
            HStack {
                ForEach(1...7, id: \.self) { day in
                    Toggle(["일", "월", "화", "수", "목", "금", "토"][day - 1], isOn: Binding(get: { draft.weekdays.contains(day) }, set: { checked in
                        if checked { draft.weekdays.append(day) } else { draft.weekdays.removeAll { $0 == day } }
                    })).toggleStyle(.checkbox)
                }
            }
            Toggle("점심시간 비우기", isOn: $draft.lunchEnabled)
            if draft.lunchEnabled {
                HStack {
                    Stepper("점심 시작 \(draft.lunchStartHour)시", value: $draft.lunchStartHour, in: 0...23)
                    Stepper("종료 \(draft.lunchEndHour)시", value: $draft.lunchEndHour, in: 1...24)
                }
            }
            Stepper("작업 사이 여유 \(draft.gapMinutes)분", value: $draft.gapMinutes, in: 0...60, step: 5)
            Toggle("작은 패널 항상 위에 표시", isOn: $draft.alwaysOnTop)
            Picker("할 일 추가 단축키", selection: $draft.shortcutKeyCode) {
                Text("⌃⌥ K").tag(UInt32(40))
                Text("⌃⌥ N").tag(UInt32(45))
                Text("⌃⌥ Space (입력 소스 단축키와 충돌 가능)").tag(UInt32(49))
            }
            Text(model.notificationStatus).font(.caption).foregroundStyle(.secondary)
            Button("알림 권한 다시 확인") { model.onNotificationRetry?() }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("취소") { dismiss() }
                Spacer()
                Button("저장") { if model.perform({ try model.store.savePreferences(draft) }) { dismiss() } }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 490)
    }
}

struct PlannerTodayView: View {
    @ObservedObject var model: PlannerModel
    var openTask: (String?) -> Void
    var quickAdd: () -> Void
    private var nextBlock: PlannerBlock? {
        model.snapshot.blocks.filter { $0.end > Date() && Calendar.current.isDateInToday($0.start) }.filter { block in
            block.taskID == nil || model.snapshot.tasks.contains { $0.id == block.taskID && $0.state != .done }
        }.min { $0.start < $1.start }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("오늘 할 일").font(.headline)
                Spacer()
                Button(action: quickAdd) { Image(systemName: "plus") }.help("할 일 추가")
                Button { openTask(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("작업창 열기")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
            if let block = nextBlock {
                VStack(alignment: .leading, spacing: 3) {
                    Text(block.start <= Date() ? "지금 · \(timeLabel(block.end))까지" : "다음 · \(timeLabel(block.start))").font(.caption).foregroundStyle(.secondary)
                    Text(block.title).font(.callout).lineLimit(2)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.12)).cornerRadius(6)
            }
            ForEach(Array(model.todayTasks.prefix(5))) { task in
                HStack(alignment: .top, spacing: 8) {
                    Button { model.complete(task) } label: { Image(systemName: "circle") }.buttonStyle(.plain)
                    Button { openTask(task.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((task.pinned ? "★ " : "") + task.title).lineLimit(2).multilineTextAlignment(.leading)
                            Text("\(projectName(task.project)) · \(task.state.title)").font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }.contextMenu {
                    Button("내일로 미루기") { model.tomorrow(task) }
                    Button(task.pinned ? "고정 해제" : "핵심으로 고정") { model.update(task) { $0.pinned.toggle() } }
                }
            }
            if model.todayTasks.isEmpty { Text("+ 버튼으로 할 일을 추가하세요.").foregroundStyle(.secondary).font(.callout) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("확인할 기록 \(model.snapshot.records.filter { !$0.resolved }.count)개").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("전체 보기") { openTask(nil) }.font(.caption)
            }
        }.padding(12)
    }
}
