import AppKit
import CatdexCore
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: StatusStore
    private let iconStore: IconSettingsStore
    private let iconProvider: StateIconProvider
    private let floatingPanel: FloatingPanelController
    private var timer: Timer?
    private var sessions: [CatdexSession] = []
    private var settingsWindowController: IconSettingsWindowController?
    private var contextPopoverController: SessionContextPopoverController?

    override init() {
        let store = StatusStore()
        let iconStore = IconSettingsStore(paths: store.paths)
        let iconProvider = StateIconProvider(store: iconStore)
        self.store = store
        self.iconStore = iconStore
        self.iconProvider = iconProvider
        floatingPanel = FloatingPanelController(iconProvider: iconProvider, settingsStore: iconStore)
        super.init()
        floatingPanel.onSessionClick = { [weak self] session, sourceView in
            self?.showSessionContext(for: session, relativeTo: sourceView)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    @objc private func refresh() {
        _ = try? store.pruneFinished(olderThan: 60 * 60 * 24)
        iconProvider.reload()
        sessions = store.loadSessions()
        statusItem.button?.title = statusTitle(for: sessions)
        statusItem.menu = makeMenu()
        floatingPanel.update(with: sessions)
    }

    private func statusTitle(for sessions: [CatdexSession]) -> String {
        let visibleSessions = sessions.filter { $0.state != .done }
        guard !visibleSessions.isEmpty else {
            return "🐱"
        }

        let activeCount = visibleSessions.filter(\.isActive).count
        let suffix = activeCount > 1 ? " \(activeCount)" : ""

        if visibleSessions.contains(where: { $0.state == .review }) {
            return "🐱❓\(suffix)"
        }
        if visibleSessions.contains(where: { $0.state == .failed }) {
            return "🙀\(suffix)"
        }
        if visibleSessions.contains(where: { $0.state == .stale }) {
            return "😿\(suffix)"
        }
        if visibleSessions.contains(where: { $0.state == .responding }) {
            return "✍️\(suffix)"
        }
        if visibleSessions.contains(where: { [.starting, .running].contains($0.state) }) {
            return "😼\(suffix)"
        }
        if visibleSessions.contains(where: { $0.state == .waiting }) {
            return "👀\(suffix)"
        }

        return "🐱"
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let visibleSessions = sessions.filter { $0.state != .done }
        let title = NSMenuItem(title: "🐱 Codex Cats", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(NSMenuItem.separator())

        if visibleSessions.isEmpty {
            let sleeping = NSMenuItem(title: "💤 자는 중... 진행 중인 Codex 작업 없음", action: nil, keyEquivalent: "")
            sleeping.isEnabled = false
            menu.addItem(sleeping)
        } else {
            for session in visibleSessions {
                let item = NSMenuItem(
                    title: menuTitle(for: session),
                    action: nil,
                    keyEquivalent: ""
                )
                item.toolTip = tooltip(for: session)
                item.submenu = makeSessionMenu(for: session)
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        addAction(floatingPanel.menuTitle, selector: #selector(toggleFloatingPanel), to: menu)
        addAction("Settings...", selector: #selector(openSettings), to: menu)
        addAction("Open Status Folder", selector: #selector(openStatusFolder), to: menu)
        addAction("Dismiss Finished", selector: #selector(dismissFinished), to: menu)
        addAction("Refresh", selector: #selector(forceRefresh), to: menu)
        menu.addItem(NSMenuItem.separator())
        addAction("Quit", selector: #selector(quit), to: menu)
        return menu
    }

    private func makeSessionMenu(for session: CatdexSession) -> NSMenu {
        let menu = NSMenu(title: session.task)

        let message = NSMenuItem(title: session.lastMessage, action: nil, keyEquivalent: "")
        message.isEnabled = false
        menu.addItem(message)
        menu.addItem(NSMenuItem.separator())

        addAction("Open Workspace", selector: #selector(openWorkspace(_:)), representedObject: session.workspace, to: menu)
        if let logPath = session.logPath {
            addAction("Open Log", selector: #selector(openPath(_:)), representedObject: logPath, to: menu)
        }
        if let codexSessionPath = session.codexSessionPath {
            addAction("Open Codex Session", selector: #selector(openPath(_:)), representedObject: codexSessionPath, to: menu)
        }
        addAction("Reveal Session JSON", selector: #selector(revealSessionJSON(_:)), representedObject: session.id, to: menu)

        if session.state.isFinished {
            menu.addItem(NSMenuItem.separator())
            addAction("Dismiss", selector: #selector(dismissSession(_:)), representedObject: session.id, to: menu)
        }

        return menu
    }

    private func addAction(
        _ title: String,
        selector: Selector,
        representedObject: Any? = nil,
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        menu.addItem(item)
    }

    private func menuTitle(for session: CatdexSession) -> String {
        let state = session.state.rawValue.uppercased()
        let branch = session.branch.map { " @\($0)" } ?? ""
        return "\(session.displayEmoji) \(state)  \(session.task)  ·  \(session.projectName)\(branch)"
    }

    private func tooltip(for session: CatdexSession) -> String {
        guard session.state == .review,
              let options = session.reviewOptions,
              !options.isEmpty
        else {
            return session.lastMessage
        }

        return ([session.lastMessage] + options.enumerated().map { index, option in
            "\(index + 1). \(option)"
        }).joined(separator: "\n")
    }

    @objc private func openWorkspace(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    @objc private func openPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func revealSessionJSON(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.sessionURL(for: id)])
    }

    @objc private func dismissSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        try? store.removeSession(id: id)
        refresh()
    }

    @objc private func dismissFinished() {
        _ = try? store.pruneFinished(olderThan: 0)
        refresh()
    }

    @objc private func openStatusFolder() {
        NSWorkspace.shared.open(store.paths.root)
    }

    @objc private func forceRefresh() {
        refresh()
    }

    @objc private func toggleFloatingPanel() {
        floatingPanel.toggle()
        statusItem.menu = makeMenu()
    }

    @objc private func openSettings() {
        let controller = settingsWindowController ?? IconSettingsWindowController(
            iconStore: iconStore,
            iconProvider: iconProvider,
            onChange: { [weak self] in
                self?.refresh()
            }
        )
        settingsWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showSessionContext(for session: CatdexSession, relativeTo sourceView: NSView) {
        let controller = contextPopoverController ?? SessionContextPopoverController(store: store)
        contextPopoverController = controller
        controller.show(session: session, relativeTo: sourceView)
    }
}

@MainActor
final class SessionContextPopoverController {
    private let store: StatusStore
    private let reader = SessionContextReader(maxEvents: 8)
    private let popover = NSPopover()

    init(store: StatusStore) {
        self.store = store
        popover.behavior = .transient
        popover.animates = false
    }

    func show(session: CatdexSession, relativeTo sourceView: NSView) {
        let context = reader.readContext(for: session)
        popover.contentViewController = SessionContextViewController(
            session: session,
            context: context,
            sessionJSONURL: store.sessionURL(for: session.id),
            onClose: { [weak self] in
                self?.popover.close()
            }
        )
        if popover.isShown {
            popover.close()
        }
        popover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .maxX)
    }
}

@MainActor
final class SessionContextViewController: NSViewController {
    private let session: CatdexSession
    private let context: CatdexSessionContext
    private let sessionJSONURL: URL
    private let onClose: () -> Void

    init(session: CatdexSession, context: CatdexSessionContext, sessionJSONURL: URL, onClose: @escaping () -> Void) {
        self.session = session
        self.context = context
        self.sessionJSONURL = sessionJSONURL
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 430, height: 500)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        stack.addArrangedSubview(makeHeaderRow())
        stack.addArrangedSubview(makeSubtitleLabel())
        stack.addArrangedSubview(makeContextScrollView())
        stack.addArrangedSubview(makeButtonRow())

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: 430),
            view.heightAnchor.constraint(equalToConstant: 500)
        ])
    }

    private func makeHeaderRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 402).isActive = true

        let title = makeTitleLabel()
        row.addArrangedSubview(title)
        row.addArrangedSubview(makeSpacer())
        row.addArrangedSubview(makeCloseButton())
        return row
    }

    private func makeTitleLabel() -> NSTextField {
        let label = NSTextField(labelWithString: session.task)
        label.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeSpacer() -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func makeCloseButton() -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(closePopover))
        button.bezelStyle = .inline
        button.isBordered = false
        button.toolTip = "Close"
        button.setContentHuggingPriority(.required, for: .horizontal)
        if let image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close") {
            button.image = image
            button.imagePosition = .imageOnly
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        } else {
            button.title = "x"
            button.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        }
        return button
    }

    private func makeSubtitleLabel() -> NSTextField {
        let branch = session.branch.map { " @\($0)" } ?? ""
        let label = NSTextField(labelWithString: "\(session.state.rawValue.uppercased()) · \(session.projectName)\(branch)")
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 402).isActive = true
        return label
    }

    private func makeContextScrollView() -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.string = contextText()

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .lineBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: 402),
            scrollView.heightAnchor.constraint(equalToConstant: 370)
        ])
        return scrollView
    }

    private func makeButtonRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        row.addArrangedSubview(button("Workspace", action: #selector(openWorkspace), isEnabled: true))
        row.addArrangedSubview(button("Log", action: #selector(openLog), isEnabled: session.logPath != nil))
        row.addArrangedSubview(button("Copy Context", action: #selector(copyContext), isEnabled: true))
        row.addArrangedSubview(button("Reveal JSON", action: #selector(revealSessionJSON), isEnabled: true))
        return row
    }

    private func button(_ title: String, action: Selector, isEnabled: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.isEnabled = isEnabled
        return button
    }

    private func contextText() -> String {
        var sections: [String] = []
        sections.append(formatSection("CURRENT", [
            ("State", session.state.rawValue.uppercased()),
            ("Last message", session.lastMessage),
            ("Updated", Self.eventTimeFormatter.string(from: session.updatedAt))
        ]))

        if let reviewOptions = session.reviewOptions, !reviewOptions.isEmpty {
            let options = reviewOptions.enumerated()
                .map { index, option in "\(index + 1). \(option)" }
                .joined(separator: "\n")
            sections.append(formatSection("REVIEW OPTIONS", [("Options", options)]))
        }

        sections.append(formatSection("LAST USER QUESTION", [
            ("Time", formattedTime(context.lastUserMessage?.timestamp)),
            ("Text", context.lastUserMessage?.detail ?? "No user question found.")
        ]))

        sections.append(formatSection("LAST ASSISTANT ANSWER", [
            ("Time", formattedTime(context.lastAssistantMessage?.timestamp)),
            ("Text", finalAnswerResult(context.lastAssistantMessage?.detail) ?? "No assistant answer found.")
        ]))

        var paths: [(String, String)] = [
            ("Workspace", session.workspace)
        ]

        if let logPath = session.logPath {
            paths.append(("Log", logPath))
        }

        if let codexSessionPath = context.codexSessionPath {
            paths.append(("Codex session", codexSessionPath))
        }
        sections.append(formatSection("PATHS", paths))

        return sections.joined(separator: "\n\n")
    }

    private func formatEvent(_ event: CatdexContextEvent) -> String {
        let time = formattedTime(event.timestamp)
        let detail = event.detail.replacingOccurrences(of: "\n", with: "\n  ")
        return "[\(time)] \(event.title)\n  \(detail)"
    }

    private func finalAnswerResult(_ answer: String?) -> String? {
        guard let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines),
              !answer.isEmpty
        else {
            return nil
        }

        let lines = answer.components(separatedBy: .newlines)
        let separatorIndex = lines.lastIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3 else { return false }
            return trimmed.allSatisfy { $0 == "-" || $0 == "_" || $0 == "*" || $0 == "─" || $0 == "━" }
        }

        guard let separatorIndex else {
            return answer
        }

        let result = lines[lines.index(after: separatorIndex)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? answer : result
    }

    private func formatSection(_ title: String, _ rows: [(String, String)]) -> String {
        let maxKeyLength = max(1, rows.map { $0.0.count }.max() ?? 1)
        let body = rows.map { key, value in
            let paddedKey = key.padding(toLength: maxKeyLength, withPad: " ", startingAt: 0)
            let formattedValue = value.replacingOccurrences(of: "\n", with: "\n\(String(repeating: " ", count: maxKeyLength + 3))")
            return "\(paddedKey) : \(formattedValue)"
        }.joined(separator: "\n")
        return "[\(title)]\n\(body)"
    }

    private func formattedTime(_ date: Date?) -> String {
        date.map { Self.eventTimeFormatter.string(from: $0) } ?? "-"
    }

    @objc private func openWorkspace() {
        NSWorkspace.shared.open(URL(fileURLWithPath: session.workspace, isDirectory: true))
    }

    @objc private func openLog() {
        guard let path = session.logPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func revealSessionJSON() {
        NSWorkspace.shared.activateFileViewerSelecting([sessionJSONURL])
    }

    @objc private func closePopover() {
        onClose()
    }

    @objc private func copyContext() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(contextText(), forType: .string)
    }

    private static let eventTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private struct IconSettings: Codable {
    var iconPaths: [String: String] = [:]
    var iconEmojis: [String: String] = [:]
    var floatingPanelOrigin: PanelOrigin?

    enum CodingKeys: String, CodingKey {
        case iconPaths
        case iconEmojis
        case floatingPanelOrigin
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        iconPaths = try container.decodeIfPresent([String: String].self, forKey: .iconPaths) ?? [:]
        iconEmojis = try container.decodeIfPresent([String: String].self, forKey: .iconEmojis) ?? [:]
        floatingPanelOrigin = try container.decodeIfPresent(PanelOrigin.self, forKey: .floatingPanelOrigin)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(iconPaths, forKey: .iconPaths)
        try container.encode(iconEmojis, forKey: .iconEmojis)
        try container.encodeIfPresent(floatingPanelOrigin, forKey: .floatingPanelOrigin)
    }
}

private struct PanelOrigin: Codable {
    var x: CGFloat
    var y: CGFloat
}

final class IconSettingsStore {
    private let settingsURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var settings: IconSettings

    init(paths: CatdexPaths) {
        settingsURL = paths.root.appendingPathComponent("settings.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        settings = Self.load(from: settingsURL, decoder: decoder)
    }

    func reload() {
        settings = Self.load(from: settingsURL, decoder: decoder)
    }

    func path(for state: CatdexState) -> String? {
        settings.iconPaths[state.rawValue]
    }

    func emoji(for state: CatdexState) -> String? {
        settings.iconEmojis[state.rawValue]
    }

    func floatingPanelOrigin() -> NSPoint? {
        guard let origin = settings.floatingPanelOrigin else { return nil }
        return NSPoint(x: origin.x, y: origin.y)
    }

    func setFloatingPanelOrigin(_ origin: NSPoint) throws {
        settings.floatingPanelOrigin = PanelOrigin(x: origin.x, y: origin.y)
        try save()
    }

    func setPath(_ path: String, for state: CatdexState) throws {
        settings.iconPaths[state.rawValue] = path
        settings.iconEmojis.removeValue(forKey: state.rawValue)
        try save()
    }

    func setEmoji(_ emoji: String, for state: CatdexState) throws {
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try removePath(for: state)
            return
        }
        settings.iconEmojis[state.rawValue] = trimmed
        settings.iconPaths.removeValue(forKey: state.rawValue)
        try save()
    }

    func removePath(for state: CatdexState) throws {
        settings.iconPaths.removeValue(forKey: state.rawValue)
        settings.iconEmojis.removeValue(forKey: state.rawValue)
        try save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(settings)
        try data.write(to: settingsURL, options: [.atomic])
    }

    private static func load(from url: URL, decoder: JSONDecoder) -> IconSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? decoder.decode(IconSettings.self, from: data)
        else {
            return IconSettings()
        }
        return settings
    }
}

@MainActor
final class StateIconProvider {
    private let store: IconSettingsStore
    private var imageCache: [CatdexState: NSImage] = [:]

    init(store: IconSettingsStore) {
        self.store = store
    }

    func reload() {
        store.reload()
        imageCache.removeAll()
    }

    func path(for state: CatdexState) -> String? {
        store.path(for: state)
    }

    func emoji(for state: CatdexState) -> String? {
        store.emoji(for: state)
    }

    func displayEmoji(for state: CatdexState, fallback: String) -> String {
        store.emoji(for: state) ?? fallback
    }

    func image(for state: CatdexState) -> NSImage? {
        if store.emoji(for: state) != nil {
            return nil
        }
        if let cached = imageCache[state] {
            return cached
        }
        guard let path = store.path(for: state),
              FileManager.default.fileExists(atPath: path),
              let image = NSImage(contentsOfFile: path)
        else {
            return nil
        }
        imageCache[state] = image
        return image
    }
}

@MainActor
final class IconSettingsWindowController: NSWindowController {
    private let iconStore: IconSettingsStore
    private let iconProvider: StateIconProvider
    private let onChange: () -> Void
    private weak var activeEmojiInput: NSTextField?

    init(iconStore: IconSettingsStore, iconProvider: StateIconProvider, onChange: @escaping () -> Void) {
        self.iconStore = iconStore
        self.iconProvider = iconProvider
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Catdex Settings"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        rebuildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func rebuildContent() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Status Icons")
        title.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        stack.addArrangedSubview(title)

        let detail = NSTextField(labelWithString: "Choose an image file for each state. SVG, PNG, JPG, PDF, ICNS, and other NSImage-readable files can be used.")
        detail.font = NSFont.systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 2
        detail.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(detail)
        detail.widthAnchor.constraint(equalToConstant: 580).isActive = true

        for state in CatdexState.allCases {
            stack.addArrangedSubview(makeRow(for: state))
        }

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -18)
        ])

        window?.contentView = root
    }

    private func makeRow(for state: CatdexState) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false

        let preview = IconPreviewView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        preview.emoji = iconProvider.emoji(for: state) ?? fallbackEmoji(for: state)
        preview.image = iconProvider.image(for: state)
        row.addArrangedSubview(preview)
        preview.widthAnchor.constraint(equalToConstant: 30).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let stateLabel = NSTextField(labelWithString: state.rawValue)
        stateLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        row.addArrangedSubview(stateLabel)
        stateLabel.widthAnchor.constraint(equalToConstant: 86).isActive = true

        let pathLabel = NSTextField(labelWithString: iconProvider.path(for: state) ?? "Default icon")
        pathLabel.font = NSFont.systemFont(ofSize: 11)
        if let emoji = iconProvider.emoji(for: state) {
            pathLabel.stringValue = "Emoji: \(emoji)"
        }
        pathLabel.textColor = iconProvider.path(for: state) == nil && iconProvider.emoji(for: state) == nil ? .secondaryLabelColor : .labelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        row.addArrangedSubview(pathLabel)
        pathLabel.widthAnchor.constraint(equalToConstant: 230).isActive = true

        let chooseButton = NSButton(title: "Choose...", target: self, action: #selector(chooseIcon(_:)))
        chooseButton.identifier = NSUserInterfaceItemIdentifier(state.rawValue)
        row.addArrangedSubview(chooseButton)

        let emojiButton = NSButton(title: "Emoji...", target: self, action: #selector(setEmoji(_:)))
        emojiButton.identifier = NSUserInterfaceItemIdentifier(state.rawValue)
        row.addArrangedSubview(emojiButton)

        let resetButton = NSButton(title: "Reset", target: self, action: #selector(resetIcon(_:)))
        resetButton.identifier = NSUserInterfaceItemIdentifier(state.rawValue)
        resetButton.isEnabled = iconProvider.path(for: state) != nil || iconProvider.emoji(for: state) != nil
        row.addArrangedSubview(resetButton)

        row.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return row
    }

    @objc private func chooseIcon(_ sender: NSButton) {
        guard let state = state(from: sender) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = IconSettingsWindowController.allowedImageTypes

        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self,
                  response == .OK,
                  let url = panel.url
            else {
                return
            }
            try? self.iconStore.setPath(url.path, for: state)
            self.iconProvider.reload()
            self.rebuildContent()
            self.onChange()
        }
    }

    @objc private func resetIcon(_ sender: NSButton) {
        guard let state = state(from: sender) else { return }
        try? iconStore.removePath(for: state)
        iconProvider.reload()
        rebuildContent()
        onChange()
    }

    @objc private func setEmoji(_ sender: NSButton) {
        guard let state = state(from: sender) else { return }
        let alert = NSAlert()
        alert.messageText = "\(state.rawValue) icon"
        alert.informativeText = "Enter an emoji or short text to use for this state."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let accessory = NSStackView(frame: NSRect(x: 0, y: 0, width: 270, height: 28))
        accessory.orientation = .horizontal
        accessory.spacing = 8
        accessory.alignment = .centerY

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = iconProvider.emoji(for: state) ?? fallbackEmoji(for: state)
        input.font = NSFont.systemFont(ofSize: 17)
        accessory.addArrangedSubview(input)
        input.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let pickerButton = NSButton(title: "😀", target: self, action: #selector(openEmojiPicker(_:)))
        pickerButton.bezelStyle = .rounded
        accessory.addArrangedSubview(pickerButton)

        alert.accessoryView = accessory
        alert.window.initialFirstResponder = input
        activeEmojiInput = input

        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            try? self.iconStore.setEmoji(input.stringValue, for: state)
            self.iconProvider.reload()
            self.rebuildContent()
            self.onChange()
        }

        DispatchQueue.main.async {
            window.makeFirstResponder(input)
            input.currentEditor()?.selectAll(nil)
        }
    }

    @objc private func openEmojiPicker(_ sender: NSButton) {
        activeEmojiInput?.window?.makeFirstResponder(activeEmojiInput)
        NSApp.orderFrontCharacterPalette(sender)
    }

    private func state(from sender: NSButton) -> CatdexState? {
        guard let value = sender.identifier?.rawValue else { return nil }
        return CatdexState(rawValue: value)
    }

    private static let allowedImageTypes: [UTType] = [
        .png,
        .jpeg,
        .gif,
        .tiff,
        .bmp,
        .icns,
        .pdf,
        UTType(filenameExtension: "svg") ?? .image
    ]

    private func fallbackEmoji(for state: CatdexState) -> String {
        CatdexSession(
            id: "preview",
            state: state,
            task: "",
            workspace: "",
            updatedAt: Date(),
            lastMessage: ""
        ).displayEmoji
    }
}

@MainActor
final class IconPreviewView: NSView {
    private let imageView = NSImageView()
    private let emojiLabel = NSTextField(labelWithString: "")

    var image: NSImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            imageView.isHidden = newValue == nil
            emojiLabel.isHidden = newValue != nil
        }
    }

    var emoji: String {
        get { emojiLabel.stringValue }
        set { emojiLabel.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.65).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        layer?.borderWidth = 1

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        emojiLabel.font = NSFont.systemFont(ofSize: 17)
        emojiLabel.alignment = .center
        emojiLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)
        addSubview(emojiLabel)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            emojiLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            emojiLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            emojiLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class FloatingPanelController {
    private let panel: NSPanel
    private let gridView: SessionGridView
    private let settingsStore: IconSettingsStore
    private var isShown = true
    private var didPlacePanel = false
    private var isProgrammaticMove = false

    var onSessionClick: ((CatdexSession, NSView) -> Void)? {
        didSet {
            gridView.onSessionClick = onSessionClick
        }
    }

    var menuTitle: String {
        isShown ? "Hide Floating Panel" : "Show Floating Panel"
    }

    init(iconProvider: StateIconProvider, settingsStore: IconSettingsStore) {
        gridView = SessionGridView(iconProvider: iconProvider)
        self.settingsStore = settingsStore
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 48, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = gridView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        gridView.onWindowDrag = { [weak self] origin, finished in
            self?.moveToUserOrigin(origin, persist: finished)
        }
    }

    func update(with sessions: [CatdexSession]) {
        gridView.sessions = sessions.filter { $0.state != .done }
        let size = gridView.preferredSize
        let savedOrigin = settingsStore.floatingPanelOrigin()
        let origin: NSPoint
        if let savedOrigin, screen(containing: savedOrigin) != nil {
            origin = savedOrigin
        } else if didPlacePanel {
            origin = panel.frame.origin
        } else {
            origin = savedOrigin ?? defaultFrame(size: size).origin
        }

        setFramePreservingUserPlacement(NSRect(origin: origin, size: size))
        didPlacePanel = true

        if isShown {
            panel.orderFrontRegardless()
        }
    }

    func toggle() {
        isShown.toggle()
        if isShown {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func moveToUserOrigin(_ origin: NSPoint, persist: Bool) {
        var frame = panel.frame
        frame.origin = origin
        setFramePreservingUserPlacement(frame)
        if persist {
            try? settingsStore.setFloatingPanelOrigin(panel.frame.origin)
        }
    }

    private func setFramePreservingUserPlacement(_ frame: NSRect) {
        isProgrammaticMove = true
        panel.setFrame(constrain(frame), display: true)
        isProgrammaticMove = false
    }

    private func constrain(_ frame: NSRect) -> NSRect {
        guard let screen = screen(containing: frame.origin) ?? NSScreen.screens.first else {
            return frame
        }
        let visible = screen.visibleFrame
        var adjusted = frame
        adjusted.origin.x = min(max(adjusted.origin.x, visible.minX), visible.maxX - min(frame.width, visible.width))
        adjusted.origin.y = min(max(adjusted.origin.y, visible.minY), visible.maxY - min(frame.height, visible.height))
        return adjusted
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            screen.visibleFrame.contains(point)
        }
    }

    private func defaultFrame(size: NSSize) -> NSRect {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: visibleFrame.maxX - size.width - 18,
            y: visibleFrame.maxY - size.height - 18,
            width: size.width,
            height: size.height
        )
    }
}

@MainActor
final class SessionGridView: NSVisualEffectView {
    private enum Layout {
        static let maxColumns = 4
        static let maxCells = 12
        static let cellWidth: CGFloat = 54
        static let cellHeight: CGFloat = 46
        static let gap: CGFloat = 6
        static let padding: CGFloat = 8
    }

    private let iconProvider: StateIconProvider
    private let dragController = WindowDragController()

    private struct CellModel {
        var title: String
        var image: NSImage?
        var subtitle: String
        var tooltip: String
        var session: CatdexSession?
    }

    var onSessionClick: ((CatdexSession, NSView) -> Void)? {
        didSet {
            subviews.compactMap { $0 as? SessionIconCell }.forEach { $0.onClick = onSessionClick }
        }
    }

    var onWindowDrag: ((NSPoint, Bool) -> Void)? {
        didSet {
            dragController.onOriginChange = onWindowDrag
            subviews.compactMap { $0 as? SessionIconCell }.forEach { $0.dragController = dragController }
        }
    }

    var sessions: [CatdexSession] = [] {
        didSet {
            rebuildCells()
        }
    }

    var preferredSize: NSSize {
        let count = max(1, min(sessions.count, Layout.maxCells))
        let columns = min(Layout.maxColumns, count)
        let rows = Int(ceil(Double(count) / Double(columns)))
        return NSSize(
            width: Layout.padding * 2 + CGFloat(columns) * Layout.cellWidth + CGFloat(columns - 1) * Layout.gap,
            height: Layout.padding * 2 + CGFloat(rows) * Layout.cellHeight + CGFloat(rows - 1) * Layout.gap
        )
    }

    init(iconProvider: StateIconProvider) {
        self.iconProvider = iconProvider
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func mouseDown(with event: NSEvent) {
        dragController.mouseDown(event, in: self)
    }

    override func mouseDragged(with event: NSEvent) {
        dragController.mouseDragged(event, in: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragController.mouseUp(event, in: self)
    }

    private func rebuildCells() {
        let models = cellModels()
        var cells = subviews.compactMap { $0 as? SessionIconCell }

        while cells.count > models.count {
            let cell = cells.removeLast()
            cell.removeFromSuperview()
        }

        while cells.count < models.count {
            let cell = makeCell()
            addSubview(cell)
            cells.append(cell)
        }

        for (cell, model) in zip(cells, models) {
            configure(cell, with: model)
        }

        layoutCells()
    }

    private func cellModels() -> [CellModel] {
        let visibleSessions = Array(sessions.prefix(Layout.maxCells))
        if visibleSessions.isEmpty {
            return [
                CellModel(
                    title: "🐱",
                    image: nil,
                    subtitle: "자는 중",
                    tooltip: "진행 중인 Codex 작업 없음",
                    session: nil
                )
            ]
        }

        var models = visibleSessions.map { session in
            CellModel(
                title: iconProvider.displayEmoji(for: session.state, fallback: session.displayEmoji),
                image: iconProvider.image(for: session.state),
                subtitle: session.task,
                tooltip: tooltip(for: session),
                session: session
            )
        }

        if sessions.count > Layout.maxCells {
            models[models.count - 1] = CellModel(
                title: "+\(sessions.count - Layout.maxCells + 1)",
                image: nil,
                subtitle: "추가",
                tooltip: "추가 세션 \(sessions.count - Layout.maxCells + 1)개",
                session: nil
            )
        }

        return models
    }

    private func makeCell() -> SessionIconCell {
        let cell = SessionIconCell(frame: .zero)
        cell.dragController = dragController
        cell.onClick = onSessionClick
        return cell
    }

    private func configure(_ cell: SessionIconCell, with model: CellModel) {
        cell.dragController = dragController
        cell.onClick = onSessionClick
        cell.session = model.session
        cell.title = model.title
        cell.iconImage = model.image
        cell.subtitle = model.subtitle
        cell.toolTip = model.tooltip
    }

    override func layout() {
        super.layout()
        layoutCells()
    }

    private func layoutCells() {
        let cells = subviews.compactMap { $0 as? SessionIconCell }
        let columns = min(Layout.maxColumns, max(1, cells.count))

        for (index, cell) in cells.enumerated() {
            let column = index % columns
            let row = index / columns
            let origin = NSPoint(
                x: Layout.padding + CGFloat(column) * (Layout.cellWidth + Layout.gap),
                y: bounds.height - Layout.padding - CGFloat(row + 1) * Layout.cellHeight - CGFloat(row) * Layout.gap
            )
            cell.frame = NSRect(origin: origin, size: NSSize(width: Layout.cellWidth, height: Layout.cellHeight))
        }
    }

    private func tooltip(for session: CatdexSession) -> String {
        let branch = session.branch.map { " @\($0)" } ?? ""
        return "\(session.state.rawValue.uppercased()) · \(session.task) · \(session.projectName)\(branch)\n\(session.lastMessage)"
    }
}

@MainActor
final class WindowDragController {
    var onOriginChange: ((NSPoint, Bool) -> Void)?

    private var startScreenPoint: NSPoint?
    private var startWindowOrigin: NSPoint?
    private var didDrag = false
    private let clickTolerance: CGFloat = 4

    func mouseDown(_ event: NSEvent, in view: NSView) {
        guard let window = view.window else { return }
        startScreenPoint = window.convertPoint(toScreen: event.locationInWindow)
        startWindowOrigin = window.frame.origin
        didDrag = false
    }

    func mouseDragged(_ event: NSEvent, in view: NSView) {
        update(event, in: view, finished: false)
    }

    @discardableResult
    func mouseUp(_ event: NSEvent, in view: NSView) -> Bool {
        update(event, in: view, finished: true)
        let wasDrag = didDrag
        startScreenPoint = nil
        startWindowOrigin = nil
        didDrag = false
        return wasDrag
    }

    private func update(_ event: NSEvent, in view: NSView, finished: Bool) {
        guard let window = view.window,
              let startScreenPoint,
              let startWindowOrigin
        else {
            return
        }

        let current = window.convertPoint(toScreen: event.locationInWindow)
        let origin = NSPoint(
            x: startWindowOrigin.x + current.x - startScreenPoint.x,
            y: startWindowOrigin.y + current.y - startScreenPoint.y
        )
        let dx = current.x - startScreenPoint.x
        let dy = current.y - startScreenPoint.y
        didDrag = didDrag || hypot(dx, dy) > clickTolerance
        if didDrag {
            onOriginChange?(origin, finished)
        }
    }
}

@MainActor
final class SessionIconCell: NSView {
    private let label = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    private let subtitleLabel = NSTextField(labelWithString: "")
    weak var dragController: WindowDragController?
    var session: CatdexSession?
    var onClick: ((CatdexSession, NSView) -> Void)?

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    var iconImage: NSImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            imageView.isHidden = newValue == nil
            label.isHidden = newValue != nil
        }
    }

    var subtitle: String {
        get { subtitleLabel.stringValue }
        set { subtitleLabel.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.68).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        layer?.borderWidth = 1

        label.font = NSFont.systemFont(ofSize: 18)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isHidden = true

        subtitleLabel.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.lineBreakMode = .byClipping
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(imageView)
        addSubview(subtitleLabel)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -4),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            imageView.widthAnchor.constraint(equalToConstant: 22),
            imageView.heightAnchor.constraint(equalToConstant: 22),
            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func mouseDown(with event: NSEvent) {
        dragController?.mouseDown(event, in: self)
    }

    override func mouseDragged(with event: NSEvent) {
        dragController?.mouseDragged(event, in: self)
    }

    override func mouseUp(with event: NSEvent) {
        let wasDrag = dragController?.mouseUp(event, in: self) ?? false
        guard !wasDrag, let session else { return }
        onClick?(session, self)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
