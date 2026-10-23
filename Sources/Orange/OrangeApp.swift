import AppKit
import SwiftUI
import OrangeCore
import OrangeArtwork
import ImageIO

@main
struct OrangeApplication {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--version") { print("Orange \(AppVersion.current)"); return }
        if CommandLine.arguments.contains("--self-check") {
            let report: [String: Any] = [
                "version": AppVersion.current,
                "minimum_macos": "13.0",
                "image_encoders": CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [],
                "ffmpeg_available": ProcessRunner.executable(named: "ffmpeg") != nil,
                "ffprobe_available": ProcessRunner.executable(named: "ffprobe") != nil,
                "ui_verification": "Not covered by this binary smoke check",
                "signed_update_configuration": (try? UpdateConfiguration(info: Bundle.main.infoDictionary ?? [:])) != nil
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), let json = String(data: data, encoding: .utf8) { print(json) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    let model = AppModel()
    private let updates = UpdateController()
    private let login = LaunchAtLogin()
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var preferencesWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var progressWindow: NSWindow?
    private var feedbackWindow: NSPanel?
    private var feedbackDismissal: DispatchWorkItem?
    private var wheel: DragWheelController?
    private var floatWindows: [NSWindow] = []
    private var updateMenuItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = OrangeArtwork.appIcon(size: 256)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = OrangeArtwork.menuIcon()
        item.button?.toolTip = "Orange · Local file converter"
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Open Orange…", action: #selector(openWindow), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Choose Files…", action: #selector(chooseFiles), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openPreferences), keyEquivalent: ",").target = self
        addUpdateItem(to: menu)
        menu.addItem(.separator())
        let wheelItem = menu.addItem(withTitle: "Finder wheels enabled", action: #selector(toggleWheel(_:)), keyEquivalent: "")
        wheelItem.state = model.wheelEnabled ? .on : .off
        wheelItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Orange", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
        installMainMenu()
        updates.isBusy = { [weak self] in self?.model.hasWorkInProgress ?? false }
        updates.onChange = { [weak self] in self?.refreshUpdateItems() }
        model.onWorkStateChange = { [weak self] in self?.updates.workStateDidChange() }
        model.onShowWindow = { [weak self] in self?.openWindow() }
        model.onBeginFinderInteraction = { [weak self] in
            self?.window?.orderOut(nil)
            self?.preferencesWindow?.orderOut(nil)
        }
        model.onShowProgress = { [weak self] in self?.showProgress() }
        model.onShowActionFeedback = { [weak self] in self?.showActionFeedback() }
        model.onPreviewWheel = { [weak self] in self?.wheel?.preview() }
        model.onFloat = { [weak self] urls in self?.showFloat(urls) }
        wheel = DragWheelController(model: model)
        if model.setupCompleted { wheel?.start(); updates.start() }
        else { showOnboarding() }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        model.select(filenames.map { URL(fileURLWithPath: $0) })
        openWindow()
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !model.setupCompleted { showOnboarding() }
        else if !flag { openPreferences() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await wheel?.stop()
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc func openWindow() {
        guard model.setupCompleted else { showOnboarding(); return }
        if window == nil {
            let view = MainView(model: model, updates: updates)
            let controller = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: controller)
            window.title = "Orange"
            window.titlebarAppearsTransparent = true
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.minSize = NSSize(width: 720, height: 610)
            window.setContentSize(NSSize(width: 860, height: 740))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func chooseFiles() {
        guard model.setupCompleted else { showOnboarding(); return }
        openWindow(); model.chooseFiles()
    }
    @objc func openPreferences() {
        if preferencesWindow == nil {
            let controller = NSHostingController(rootView: PreferencesView(model: model, login: login, updates: updates))
            let window = NSWindow(contentViewController: controller)
            window.title = "Orange Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 640, height: 700))
            window.isReleasedWhenClosed = false
            window.center()
            preferencesWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    private func showOnboarding() {
        if onboardingWindow == nil {
            let content = OnboardingView(model: model, login: login) { [weak self] in
                guard let self else { return }
                self.model.setupCompleted = true
                self.wheel?.start()
                self.updates.start()
                self.onboardingWindow?.close()
                if let message = self.login.registrationMessage { self.model.showFeedback(message) }
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: content))
            window.title = "Set up Orange"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    private func showProgress() {
        if progressWindow == nil {
            let window = NSPanel(contentViewController: NSHostingController(rootView: ActivityPanel(model: model)))
            window.title = "Orange · Activity"
            window.styleMask = [.titled, .closable, .utilityWindow]
            window.setContentSize(NSSize(width: 390, height: 270))
            window.isReleasedWhenClosed = false
            window.center()
            progressWindow = window
        }
        progressWindow?.orderFrontRegardless()
    }

    private func showActionFeedback() {
        feedbackDismissal?.cancel()
        if feedbackWindow == nil {
            let panel = NSPanel(contentViewController: NSHostingController(rootView: ActionNotice(model: model)))
            panel.title = "Orange"
            panel.styleMask = [.titled, .closable, .nonactivatingPanel]
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.setContentSize(NSSize(width: 360, height: 108))
            if let screen = NSScreen.main {
                panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 384, y: screen.visibleFrame.minY + 24))
            }
            feedbackWindow = panel
        }
        feedbackWindow?.orderFrontRegardless()
        let dismissal = DispatchWorkItem { [weak self] in self?.feedbackWindow?.orderOut(nil) }
        feedbackDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: dismissal)
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appMenu = NSMenu(title: "Orange")
        appMenu.addItem(withTitle: "Settings…", action: #selector(openPreferences), keyEquivalent: ",").target = self
        addUpdateItem(to: appMenu)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Orange", action: #selector(quit), keyEquivalent: "q").target = self
        let appItem = main.addItem(withTitle: "Orange", action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Open Orange…", action: #selector(openWindow), keyEquivalent: "o").target = self
        file.addItem(withTitle: "Choose Files…", action: #selector(chooseFiles), keyEquivalent: "n").target = self
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        NSApp.mainMenu = main
    }
    @objc func toggleWheel(_ sender: NSMenuItem) {
        guard model.setupCompleted else { showOnboarding(); return }
        model.wheelEnabled.toggle()
        sender.state = model.wheelEnabled ? .on : .off
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc private func checkForUpdates() { updates.checkForUpdates() }

    private func addUpdateItem(to menu: NSMenu) {
        let item = menu.addItem(withTitle: updates.buttonTitle, action: #selector(checkForUpdates), keyEquivalent: "")
        item.target = self
        updateMenuItems.append(item)
    }

    private func refreshUpdateItems() {
        for item in updateMenuItems {
            item.title = updates.buttonTitle
            item.isEnabled = updates.canCheckForUpdates && !updates.installationWaitingForWork
        }
        statusItem?.button?.toolTip = updates.availableVersion.map { "Orange · Update to \($0) available" } ?? "Orange · Local file converter"
    }

    func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items where item.action == #selector(toggleWheel(_:)) {
            item.title = model.setupCompleted ? "Finder wheels enabled" : "Finish setting up Orange…"
            item.state = model.setupCompleted && model.wheelEnabled ? .on : .off
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) {
            return updates.canCheckForUpdates && !updates.installationWaitingForWork
        }
        return true
    }

    private func showFloat(_ urls: [URL]) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 150), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Orange · File shelf"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: FloatView(urls: urls))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        floatWindows.removeAll { !$0.isVisible }
        floatWindows.append(panel)
    }
}

enum OrangeArtwork {
    static func menuIcon() -> NSImage { OrangeIcon.menuImage() }
    static func appIcon(size: CGFloat) -> NSImage { OrangeIcon.image(size: size) }
}

private struct ActionNotice: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: OrangeArtwork.appIcon(size: 52)).resizable().frame(width: 44, height: 44)
            Text(model.actionFeedback ?? "").font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(20).frame(width: 360, height: 108)
    }
}
