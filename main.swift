import Carbon
import Cocoa
import ServiceManagement

// MARK: - Finder

// Asking Finder over Apple Events is the only permission-light way to get a guaranteed new
// window. NSWorkspace/`open` on a folder just brings forward any window already showing it,
// and synthesizing ⌘N would need Accessibility. This costs one Automation prompt.
//
// A bare `make new Finder window` always opens the Computer view, ignoring Finder's "New
// Finder windows show" setting, so the target is read from Finder's prefs on every press
// (the setting can change at any time) to match what ⌘N does. No saved target means Recents,
// which is a canned search rather than a folder. The window is made before activating so
// Finder lands on it here instead of jumping to another Space.
enum Finder {
    enum Failure {
        case notAuthorized
        case other(String)
    }

    private static let recentsPath = "/System/Library/CoreServices/Finder.app/Contents/Resources/MyLibraries/myDocuments.cannedSearch"
    private static let domain = "com.apple.finder" as CFString

    // nil means the Computer view, the one target a bare `make new Finder window` gets right.
    private static var newWindowPath: String? {
        CFPreferencesAppSynchronize(domain)
        let target = CFPreferencesCopyAppValue("NewWindowTarget" as CFString, domain) as? String
        if target == "PfCm" { return nil }

        if let saved = CFPreferencesCopyAppValue("NewWindowTargetPath" as CFString, domain) as? String,
           let path = URL(string: saved)?.path,
           FileManager.default.fileExists(atPath: path) {
            return path
        }
        return recentsPath
    }

    static func openNewWindow() -> Failure? {
        var makeWindow = "make new Finder window"
        if let path = newWindowPath {
            let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            makeWindow += " to (POSIX file \"\(escaped)\")"
        }

        var error: NSDictionary?
        NSAppleScript(source: """
            tell application "Finder"
                \(makeWindow)
                activate
            end tell
            """)?.executeAndReturnError(&error)
        guard let error else { return nil }
        if error[NSAppleScript.errorNumber] as? Int == Int(errAEEventNotPermitted) {
            return .notAuthorized
        }
        return .other(error[NSAppleScript.errorMessage] as? String ?? "Unknown error")
    }
}

// MARK: - Hotkey

final class HotKey {
    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.onPress?() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    @discardableResult
    func register() -> Bool {
        guard ref == nil else { return true }
        let id = EventHotKeyID(signature: OSType(0x434D_4445), id: 1) // 'CMDE'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_E), UInt32(cmdKey), id, GetApplicationEventTarget(), 0, &ref)
        return status == noErr
    }

    func unregister() {
        guard let ref else { return }
        UnregisterEventHotKey(ref)
        self.ref = nil
    }
}

// MARK: - Settings

enum AppSettings {
    private static let enabledKey = "enabled"
    private static let loginItemOfferedKey = "loginItemOffered"

    static var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var loginItemOffered: Bool {
        get { UserDefaults.standard.bool(forKey: loginItemOfferedKey) }
        set { UserDefaults.standard.set(newValue, forKey: loginItemOfferedKey) }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let hotKey = HotKey()

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.image = AppDelegate.statusIcon
        }
        enableLoginItemOnFirstRun()
        buildMenu()
        hotKey.onPress = { [weak self] in self?.openFinderWindow() }
        refresh()
    }

    // A hotkey that silently stops working after a reboot is the one way this app can feel
    // broken, so it starts as a login item once. Only from /Applications: a login item
    // registered from a build folder would point at a path that later disappears.
    private func enableLoginItemOnFirstRun() {
        guard !AppSettings.loginItemOffered, Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        AppSettings.loginItemOffered = true
        try? SMAppService.mainApp.register()
    }

    private func buildMenu() {
        statusLine.isEnabled = false

        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())

        menu.addItem(withTitle: "New Finder Window", action: #selector(openFinderWindow), keyEquivalent: "").target = self
        enabledItem.target = self
        menu.addItem(enabledItem)
        menu.addItem(.separator())

        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())

        menu.addItem(withTitle: "☕ Buy Me a Coffee", action: #selector(openBuyMeACoffee), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Uninstall CmdE…", action: #selector(uninstall), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit CmdE", action: #selector(quit), keyEquivalent: "q").target = self

        statusItem.menu = menu
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleEnabled() {
        AppSettings.enabled = enabledItem.state != .on
        refresh()
    }

    private func refresh() {
        enabledItem.state = AppSettings.enabled ? .on : .off

        guard AppSettings.enabled else {
            hotKey.unregister()
            statusLine.title = "Disabled"
            return
        }

        statusLine.title = hotKey.register() ? "⌘E opens a new Finder window" : "⌘E is taken by another app"
    }

    @objc private func openFinderWindow() {
        switch Finder.openNewWindow() {
        case nil:
            break
        case .notAuthorized:
            let alert = NSAlert()
            alert.messageText = "CmdE needs permission to control Finder"
            alert.informativeText = "Turn on Finder under CmdE in System Settings > Privacy & Security > Automation."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        case .other(let message):
            let alert = NSAlert()
            alert.messageText = "Couldn't open a Finder window"
            alert.informativeText = message
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // A folder with the E knocked out of it, the same mark as the Dock icon.
    private static let statusIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let body = NSBezierPath(roundedRect: NSRect(x: 1, y: 2.5, width: 16, height: 11.5), xRadius: 2, yRadius: 2)
            let tab = NSBezierPath(roundedRect: NSRect(x: 1, y: 11, width: 7, height: 5), xRadius: 1.5, yRadius: 1.5)
            NSColor.black.setFill()
            body.fill()
            tab.fill()

            let barWidth: CGFloat = 5.5
            let barHeight: CGFloat = 1.5
            let left: CGFloat = 6.5
            let bottom: CGFloat = 4
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(rect: NSRect(x: left, y: bottom, width: barHeight, height: 8)).fill()
            for y in [bottom, bottom + 3.25, bottom + 6.5] {
                NSBezierPath(rect: NSRect(x: left, y: y, width: barWidth, height: barHeight)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    @objc private func toggleLoginItem() {
        do {
            if loginItem.state == .on {
                try SMAppService.mainApp.unregister()
                loginItem.state = .off
            } else {
                try SMAppService.mainApp.register()
                loginItem.state = .on
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't update Login Item"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func openBuyMeACoffee() {
        if let url = URL(string: "https://buymeacoffee.com/jackharvest") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func uninstall() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall CmdE?"
        alert.informativeText = "This releases ⌘E, removes CmdE from Login Items, clears its saved settings and Finder permission, and moves CmdE.app to the Trash. You can restore it from the Trash if you change your mind."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        hotKey.unregister()
        try? SMAppService.mainApp.unregister()
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/tccutil"), arguments: ["reset", "AppleEvents", bundleID])
        }

        let bundleURL = Bundle.main.bundleURL
        try? FileManager.default.trashItem(at: bundleURL, resultingItemURL: nil)

        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
