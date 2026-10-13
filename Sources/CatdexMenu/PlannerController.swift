import AppKit
import SwiftUI
import Carbon
import OSLog
import CatdexCore
@preconcurrency import UserNotifications

@MainActor
final class PlannerModel: ObservableObject {
    let store: PlannerStore
    @Published var snapshot = PlannerSnapshot()
    @Published var error: String?
    @Published var notificationStatus = "알림 권한을 확인하려면 일정을 등록하세요."
    var onNotificationRetry: (() -> Void)?
    @Published var selectedTaskID: String?
    @Published var selectedRecordID: String?
    @Published var section = "week"
    @Published var search = ""
    @Published var projectFilter = ""
    @Published var day = Date()
    @Published var showTimeline = true
    @Published var proposal: ScheduleProposal?
    var proposalSnapshot: PlannerSnapshot?
    var onChange: (() -> Void)?
    init(store: PlannerStore = PlannerStore()) { self.store = store; reload() }
    func reload() {
        do {
            let new = try store.snapshot()
            if new != snapshot { snapshot = new; onChange?() }
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func perform(_ operation: () throws -> Void) -> Bool {
        do { try operation(); error = nil; reload(); return true }
        catch { self.error = error.localizedDescription; reload(); return false }
    }
    var todayTasks: [PlannerTask] {
        snapshot.tasks.filter { PlannerScheduler.isToday($0, day: Date()) }.sorted(by: PlannerTask.precedes)
    }
    var projects: [String] { Array(Set(snapshot.records.map(\.project).filter { !$0.isEmpty })).sorted() }
    func update(_ task: PlannerTask, _ edit: (inout PlannerTask) -> Void) {
        var value = task; edit(&value); perform { try store.saveTask(value) }
    }
    func complete(_ task: PlannerTask) { update(task) { $0.state = $0.state == .done ? .todo : .done } }
    @discardableResult
    func moveTask(_ id: String, relativeTo targetID: String?, after: Bool = false, toDay day: Date? = nil) -> Bool {
        guard let task = snapshot.tasks.first(where: { $0.id == id }), id != targetID else { return false }
        let target = targetID.flatMap { id in snapshot.tasks.first { $0.id == id } }
        guard targetID == nil || target != nil else { return false }
        return perform { try store.moveTask(task, relativeTo: target, after: after, toDay: day) }
    }
    func moveTask(_ task: PlannerTask, step: Int, in visibleTasks: [PlannerTask]) {
        guard let index = visibleTasks.firstIndex(where: { $0.id == task.id }),
              visibleTasks.indices.contains(index + step) else { return }
        moveTask(task.id, relativeTo: visibleTasks[index + step].id, after: step > 0)
    }
    func tomorrow(_ task: PlannerTask) {
        update(task) {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
            $0.plannedDay = tomorrow; $0.pinned = false
            if $0.state == .waiting { $0.reviewAt = tomorrow }
        }
    }
    func recommend(reschedule: Bool = false) {
        reload(); proposalSnapshot = snapshot
        proposal = PlannerScheduler.propose(snapshot: snapshot, day: day, rescheduleOverdue: reschedule)
    }
    func confirmProposal() {
        guard let proposal, let expected = proposalSnapshot else { return }
        guard proposal.blocks.allSatisfy({ $0.start > Date() }) else {
            error = "추천 시작 시간이 지났습니다. 다시 계산해 주세요."; return
        }
        // Only remove an overdue block if its replacement was actually accepted.
        let accepted = Set(proposal.blocks.compactMap(\.taskID))
        let replacing = proposal.replacing.filter { $0.taskID.map(accepted.contains) == true }
        if perform({ try store.addBlocks(proposal.blocks, replacing: replacing, expected: expected, enforceRecommendation: true) }) {
            self.proposal = nil; proposalSnapshot = nil
        }
    }
    func place(taskID: String, at start: Date) {
        guard let task = snapshot.tasks.first(where: { $0.id == taskID }) else { return }
        let block = PlannerBlock(taskID: task.id, title: task.title, start: start,
                                 end: start.addingTimeInterval(Double(task.estimatedMinutes ?? 30) * 60))
        let replacing = snapshot.blocks.filter { $0.taskID == taskID }
        perform { try store.addBlocks([block], replacing: replacing, expected: snapshot) }
    }
    func context(for task: PlannerTask) -> String {
        let record = snapshot.records.first { $0.id == task.recordID }
        return "프로젝트: \(task.project)\n작업: \(task.title)\n중단 메모: \(task.pauseNote)\n\n기록: \(record?.text ?? "")\n\n맥락: \(record?.context ?? "")"
    }
}

@MainActor
final class PlannerController: NSObject, UNUserNotificationCenterDelegate {
    let model = PlannerModel()
    private var window: NSWindow?
    private var quickWindow: NSPanel?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var registeredShortcut: String?
    private var scheduledSignature: String?
    private var notificationTask: Task<Void, Never>?
    private var notificationsRequested = false
    private var lifecycleObservers: [NSObjectProtocol] = []
    private let notificationLogger = Logger(subsystem: "dev.catdex.CatdexMenu", category: "planner-notifications")
    var selectedProject = ""
    var onPreferencesChanged: ((PlannerPreferences) -> Void)?
    static weak var active: PlannerController?

    override init() {
        super.init()
        Self.active = self
        model.onChange = { [weak self] in self?.applySettings() }
        model.onNotificationRetry = { [weak self] in
            self?.notificationsRequested = false; self?.scheduledSignature = nil; self?.syncNotifications()
        }
        lifecycleObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduledSignature = nil; self?.syncNotifications() }
        })
        lifecycleObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduledSignature = nil; self?.syncNotifications() }
        })
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
        applySettings()
    }
    func refresh() { model.reload(); syncNotifications() }
    func show(taskID: String? = nil) {
        if let taskID { model.selectedTaskID = taskID; model.selectedRecordID = nil; model.showTimeline = false }
        if window == nil {
            let view = PlannerRootView(model: model, quickAdd: { [weak self] in self?.showQuickAdd() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1380, height: 790),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Catdex · 작업 플래너"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view); window.minSize = NSSize(width: 1180, height: 620)
            window.center(); window.setFrameAutosaveName("CatdexPlannerWindow")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    func showQuickAdd() {
        if quickWindow?.isVisible == true {
            NSApp.activate(ignoringOtherApps: true); quickWindow?.makeKeyAndOrderFront(nil); return
        }
        model.error = nil
        if quickWindow == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Catdex · 할 일 추가"; panel.isReleasedWhenClosed = false
            panel.level = .floating; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            quickWindow = panel
        }
        quickWindow?.contentView = NSHostingView(rootView: QuickTaskView(model: model, initialDay: model.day, project: selectedProject, onCancel: { [weak self] in
            self?.quickWindow?.orderOut(nil)
        }, onSave: { [weak self] in
            self?.quickWindow?.orderOut(nil)
            self?.model.section = "week"; self?.model.showTimeline = true
            self?.model.search = ""; self?.model.projectFilter = ""; self?.show()
        }))
        quickWindow?.center(); NSApp.activate(ignoringOtherApps: true); quickWindow?.makeKeyAndOrderFront(nil)
    }

    func applySettings() {
        onPreferencesChanged?(model.snapshot.preferences)
        registerShortcut()
        syncNotifications()
    }
    private func registerShortcut() {
        let prefs = model.snapshot.preferences
        let signature = "\(prefs.shortcutKeyCode)-\(prefs.shortcutModifiers)"
        guard registeredShortcut != signature else { return }
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if hotKeyHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { PlannerController.active?.showQuickAdd() }
                return noErr
            }, 1, &spec, nil, &hotKeyHandler)
        }
        let status = RegisterEventHotKey(prefs.shortcutKeyCode, prefs.shortcutModifiers,
                                        EventHotKeyID(signature: 0x43415450, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        registeredShortcut = signature
        if status != noErr { model.error = "빠른 기록 단축키가 다른 앱과 충돌합니다. 플래너 설정에서 변경하세요." }
    }
    private func syncNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let tasks = Dictionary(uniqueKeysWithValues: model.snapshot.tasks.map { ($0.id, $0) })
        let eligible = model.snapshot.blocks.filter {
            $0.taskID.flatMap { tasks[$0]?.state }.map { $0 != .done && $0 != .waiting } == true
        }
        let upcoming = eligible.filter { $0.start > Date() }.sorted { $0.start < $1.start }
        let signature = model.snapshot.tasks.map { "\($0.id):\($0.state.rawValue)" }.joined(separator: ",") + upcoming.map { "\($0.id)|\($0.start.timeIntervalSince1970)|\($0.title)" }.joined(separator: ";")
        guard signature != scheduledSignature else { return }
        scheduledSignature = signature
        let center = UNUserNotificationCenter.current()
        let open = UNNotificationAction(identifier: "planner.open", title: "상세 열기", options: [.foreground])
        let snooze = UNNotificationAction(identifier: "planner.snooze", title: "10분 뒤 알림", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: "planner.task", actions: [open, snooze], intentIdentifiers: [])])
        notificationTask?.cancel()
        notificationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if !notificationsRequested && !upcoming.isEmpty {
                notificationsRequested = true
                do {
                    _ = try await center.requestAuthorization(options: [.alert, .sound])
                } catch {
                    model.notificationStatus = "알림 권한 요청 실패: \(error.localizedDescription)"
                    notificationLogger.error("Authorization request failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            let settings = await center.notificationSettings()
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                model.notificationStatus = "시스템 알림 허용됨"
            case .notDetermined:
                model.notificationStatus = "알림 권한 응답 대기 중입니다. macOS 알림 센터에서 CatdexMenu의 요청을 확인하세요."
            case .denied:
                model.notificationStatus = "알림이 허용되지 않았습니다. 시스템 설정 → 알림 → CatdexMenu에서 허용하세요."
            default:
                model.notificationStatus = "시스템 알림 권한 상태를 확인할 수 없습니다."
            }
            guard !Task.isCancelled, self.scheduledSignature == signature else { return }
            notificationLogger.info("Authorization status: \(settings.authorizationStatus.rawValue, privacy: .public)")
            let pending = await center.pendingNotificationRequests()
            guard !Task.isCancelled, self.scheduledSignature == signature else { return }
            let activeIDs = Set(model.snapshot.tasks.filter { $0.state != .done && $0.state != .waiting }.map(\.id))
            let eligibleRequestIDs = Set(eligible.map { "planner.block." + $0.id })
            center.removePendingNotificationRequests(withIdentifiers: pending.filter {
                ($0.identifier.hasPrefix("planner.block.") && !eligibleRequestIDs.contains($0.identifier)) ||
                ($0.identifier.hasPrefix("planner.snooze.") && !activeIDs.contains($0.content.userInfo["taskID"] as? String ?? ""))
            }.map(\.identifier))
            guard allowed else { return }
            for block in upcoming.prefix(50) {
                guard !Task.isCancelled else { return }
                let identifier = "planner.block." + block.id
                if let existing = pending.first(where: { $0.identifier == identifier }),
                   existing.content.body == block.title,
                   existing.content.userInfo["start"] as? Double == block.start.timeIntervalSince1970 { continue }
                let content = UNMutableNotificationContent()
                content.title = "🐱 작업 시작"; content.body = block.title; content.sound = .default
                content.categoryIdentifier = "planner.task"; content.userInfo = ["taskID": block.taskID ?? "", "start": block.start.timeIntervalSince1970]
                var dateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: block.start)
                dateComponents.timeZone = .current
                let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
                do {
                    try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
                    notificationLogger.info("Scheduled \(identifier, privacy: .public) at \(block.start.description, privacy: .public)")
                } catch { self.model.error = "작업 알림을 예약하지 못했습니다: \(error.localizedDescription)" }
            }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let taskID = response.notification.request.content.userInfo["taskID"] as? String
        if response.actionIdentifier == "planner.snooze" {
            if let content = response.notification.request.content.mutableCopy() as? UNMutableNotificationContent {
                center.add(UNNotificationRequest(identifier: "planner.snooze." + (taskID ?? UUID().uuidString), content: content,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false)))
            }
        } else {
            Task { @MainActor in self.show(taskID: taskID) }
        }
        completionHandler()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Logger(subsystem: "dev.catdex.CatdexMenu", category: "planner-notifications").info("Presented \(notification.request.identifier, privacy: .public)")
        completionHandler([.banner, .sound])
    }
}
