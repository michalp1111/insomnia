import AppKit
import SwiftUI

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private static let openEye = StatusIcon.image(open: true)
    private static let closedEye = StatusIcon.image(open: false)
    private static let duration: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .short
        return formatter
    }()

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    private let insomnia: Insomnia
    private let updater: Updater?
    private let header = HeaderView()
    private static let rate = ByteCountFormatter()

    private let workingOption = OptionView(symbol: "hourglass", title: "While Working")
    private let alwaysOption = OptionView(symbol: "infinity", title: "Until Turned Off")
    private let note = NoteView()
    lazy var settings: NSWindow = {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(insomnia: insomnia)))
        window.title = "Insomnia Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }()
    private var workViews: [WorkView] = []
    private var structure = ""
    private var isOpen = false
    private var shownAwake: Bool?
    private var shownOn: Bool?
    // A file system check, so it is made when the menu opens rather than on every refresh.
    private lazy var canKeepLidClosed = insomnia.power.canKeepLidClosed

    init(insomnia: Insomnia, updater: Updater?) {
        self.insomnia = insomnia
        self.updater = updater
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.toolTip = "Insomnia"
        note.text = "Nothing at the moment"
        header.toggle.target = self
        header.toggle.action = #selector(toggle)
        workingOption.onSelect = { [weak self] in self?.choose(.working) }
        alwaysOption.onSelect = { [weak self] in self?.choose(.always) }
        insomnia.onChange = { [weak self] in self?.update() }
        updater?.onChange = { [weak self] in self?.update() }
        update()
        updateMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        canKeepLidClosed = insomnia.power.canKeepLidClosed
        updateMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        insomnia.isWatching = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        insomnia.isWatching = false
    }

    /// Touches the menu bar only when its state changes; the menu itself only while it is open.
    private func update() {
        let awake = insomnia.awakeSince != nil
        if awake != shownAwake {
            shownAwake = awake
            statusItem.button?.image = awake ? Self.openEye : Self.closedEye
        }
        if insomnia.isOn != shownOn {
            shownOn = insomnia.isOn
            statusItem.button?.appearsDisabled = !insomnia.isOn
        }
        if isOpen { updateMenu() }
    }

    private func updateMenu() {
        let rows = workRows
        let structure = "\(insomnia.mode) \(rows.count) \(canKeepLidClosed) \(updater?.version ?? "") \(updater?.isInstalling == true)"
        if structure != self.structure {
            self.structure = structure
            rebuild(workRows: rows.count)
        }

        header.toggle.state = insomnia.isOn ? .on : .off
        header.statusText = status
        workingOption.isSelected = insomnia.mode == .working
        alwaysOption.isSelected = insomnia.mode == .always
        for (view, row) in zip(workViews, rows) { view.row = row }
    }

    private func rebuild(workRows: Int) {
        menu.removeAllItems()
        menu.addItem(item(view: header))
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Stay Awake"))
        menu.addItem(item(view: workingOption, action: #selector(pick)))
        menu.addItem(item(view: alwaysOption, action: #selector(pick)))

        if insomnia.mode == .working {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Working Now"))
            while workViews.count < workRows { workViews.append(WorkView()) }
            workViews.removeLast(workViews.count - workRows)
            for view in workViews { menu.addItem(item(view: view, enabled: false)) }
            if workRows == 0 { menu.addItem(item(view: note, enabled: false)) }
        }

        if !canKeepLidClosed {
            menu.addItem(.separator())
            menu.addItem(item("Stay Awake with Lid Closed…", #selector(allowClosedLid)))
        }

        menu.addItem(.separator())
        if let updater, let version = updater.version {
            let update = item(updater.isInstalling ? "Updating to \(version)…" : "Update to \(version)", #selector(installUpdate))
            update.isEnabled = !updater.isInstalling
            menu.addItem(update)
        }
        menu.addItem(item("About Insomnia", #selector(about)))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Quit Insomnia", #selector(quit), key: "q"))
    }

    private var status: String {
        guard insomnia.isOn else { return "Your Mac sleeps as usual" }
        switch insomnia.pause {
        case .battery: return "Paused while the battery is low"
        case .heat: return "Paused while your Mac cools down"
        case nil: break
        }
        guard let since = insomnia.awakeSince else { return "Waiting for work" }
        if let sleepsAt = insomnia.sleepsAt {
            return "Work is done, sleep in \(max(1, Int((sleepsAt.timeIntervalSinceNow / 60).rounded(.up)))) min"
        }
        if insomnia.mode == .working {
            var names: [String] = []
            for name in insomnia.apps.map(\.name) + insomnia.agents.filter(\.isWorking).map(\.name) where !names.contains(name) {
                names.append(name)
            }
            let count = names.count + (insomnia.upload > 0 ? 1 : 0)
            switch count {
            case 1: return names.first.map { "Awake while \($0) works" } ?? "Awake while uploading"
            case 2 where names.count == 2: return "Awake while \(names[0]) and \(names[1]) work"
            default: return "Awake while \(names[0]) and \(count - 1) more work"
            }
        }
        let elapsed = Date.now.timeIntervalSince(since)
        guard elapsed >= 60 else { return "Keeping your Mac awake" }
        return "Awake for \(Self.duration.string(from: elapsed) ?? "")"
    }

    /// Busy apps, then working agents with one row per project and agent, then the upload.
    private var workRows: [WorkRow] {
        var agents: [(project: String, name: String, count: Int)] = []
        for agent in insomnia.agents where agent.isWorking {
            if let index = agents.firstIndex(where: { $0.project == agent.project && $0.name == agent.name }) {
                agents[index].count += 1
            } else {
                agents.append((agent.project, agent.name, 1))
            }
        }
        var rows = insomnia.apps.map { WorkRow(title: $0.name, bundle: $0.bundle) }
        rows += agents.map { WorkRow(title: $0.project, detail: $0.count > 1 ? "\($0.name) ×\($0.count)" : $0.name) }
        if insomnia.upload > 0 {
            rows.append(WorkRow(title: "Uploading", detail: "\(Self.rate.string(fromByteCount: Int64(insomnia.upload)))/s",
                                symbol: "arrow.up.circle"))
        }
        return rows
    }

    @objc private func toggle(_ sender: NSSwitch) {
        turn(on: sender.state == .on)
    }

    /// Picking how to stay awake also turns Insomnia on, like choosing a Focus.
    private func choose(_ mode: Insomnia.Mode) {
        insomnia.mode = mode
        turn(on: true)
    }

    /// The first time Insomnia goes on it asks for the closed-lid permission.
    private func turn(on: Bool) {
        insomnia.isOn = on
        let defaults = UserDefaults.standard
        guard on, !canKeepLidClosed, !defaults.bool(forKey: "askedForClosedLid") else { return }
        defaults.set(true, forKey: "askedForClosedLid")
        menu.cancelTracking()
        // The default mode only comes back once the menu is gone.
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { self.allowClosedLid() }
        }
    }

    /// Return on a highlighted option; clicks go to the view itself.
    @objc private func pick(_ sender: NSMenuItem) {
        (sender.view as? OptionView)?.onSelect()
    }

    @objc private func allowClosedLid() {
        insomnia.power.allowClosedLid()
        canKeepLidClosed = insomnia.power.canKeepLidClosed
        updateMenu()
    }

    static var credits: NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                                         .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
        let credits = NSMutableAttributedString(string: "Made by Michal Ptacek, founder of ", attributes: attributes)
        credits.append(NSAttributedString(string: "CzechCrunch",
                                          attributes: attributes.merging([.link: URL(string: "https://cc.cz")!]) { $1 }))
        return credits
    }

    @objc private func installUpdate() {
        Task { await updater?.install() }
    }

    @objc private func about() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.credits])
    }

    @objc func openSettings() {
        NSApp.activate()
        settings.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func item(view: NSView, enabled: Bool = true, action: Selector? = nil) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = enabled
        item.action = action
        item.target = self
        return item
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}
