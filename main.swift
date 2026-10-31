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

// MARK: - Updates

// Same shape as Marquee's AppUpdater: read the latest GitHub release, download its "-app.zip"
// asset, swap it in for the running bundle. Every release MUST publish exactly one such asset
// with CmdE.app at its root (release.sh builds it) or there's nothing to install.
struct AppUpdate {
    let version: String
    let assetURL: URL
    let notes: String
}

enum UpdateError: LocalizedError {
    case malformedRelease, invalidDownload, notInApplications

    var errorDescription: String? {
        switch self {
        case .malformedRelease: return "Couldn't read the latest release."
        case .invalidDownload: return "The downloaded update wasn't a valid copy of CmdE."
        case .notInApplications: return "Move CmdE to your Applications folder to update it."
        }
    }
}

enum Updater {
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/jackharvest/CmdE/releases/latest")!

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // Updating (and the login item) only make sense for a real install. A build folder or a copy
    // running straight from the DMG shouldn't replace itself.
    static var isInstalled: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    static func latestRelease() async throws -> AppUpdate {
        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix("-app.zip") == true }),
              let urlString = asset["browser_download_url"] as? String,
              let url = URL(string: urlString)
        else { throw UpdateError.malformedRelease }
        return AppUpdate(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, assetURL: url, notes: json["body"] as? String ?? "")
    }

    // Numeric compare, since a string compare would sort "1.10" before "1.2".
    static func isNewer(_ version: String) -> Bool {
        let new = version.split(separator: ".").compactMap { Int($0) }
        let old = currentVersion.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(new.count, old.count) {
            let a = i < new.count ? new[i] : 0
            let b = i < old.count ? old[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    static func install(_ update: AppUpdate) async throws {
        guard isInstalled else { throw UpdateError.notInApplications }

        let (download, _) = try await URLSession.shared.download(from: update.assetURL)
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let zip = workDir.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: download, to: zip)
        guard run("/usr/bin/ditto", "-x", "-k", zip.path, workDir.path) else { throw UpdateError.invalidDownload }

        // Nothing is left to catch a bad bundle once it's in place, and a version mismatch would
        // reinstall the same release on every check, so refuse anything that isn't exactly this.
        let newApp = workDir.appendingPathComponent("CmdE.app")
        guard let info = Bundle(url: newApp)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == update.version,
              run("/usr/bin/codesign", "--verify", "--deep", newApp.path)
        else { throw UpdateError.invalidDownload }

        // The old copy moves aside rather than being deleted, so a failed swap can roll back.
        let current = Bundle.main.bundleURL
        let backup = current.deletingLastPathComponent().appendingPathComponent(".CmdE-preupdate.bak")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.moveItem(at: current, to: backup)
        do {
            try FileManager.default.moveItem(at: newApp, to: current)
        } catch {
            try? FileManager.default.removeItem(at: current)
            try? FileManager.default.moveItem(at: backup, to: current)
            throw error
        }
        try? FileManager.default.removeItem(at: backup)
    }

    private static func run(_ path: String, _ arguments: String...) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

// MARK: - Settings

enum AppSettings {
    private static let enabledKey = "enabled"
    private static let loginItemOfferedKey = "loginItemOffered"
    private static let autoUpdateKey = "autoUpdate"
    private static let lastUpdateCheckKey = "lastUpdateCheck"

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

    static var autoUpdate: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoUpdateKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: autoUpdateKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoUpdateKey) }
    }

    static var lastUpdateCheck: Date? {
        get { UserDefaults.standard.object(forKey: lastUpdateCheckKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastUpdateCheckKey) }
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let hotKey = HotKey()
    private var updateTimer: Timer?
    private var isUpdating = false

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
    private let checkUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
    private let autoUpdateItem = NSMenuItem(title: "Install Updates Automatically", action: #selector(toggleAutoUpdate), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.image = AppDelegate.statusIcon
        }
        enableLoginItemOnFirstRun()
        buildMenu()
        hotKey.onPress = { [weak self] in self?.openFinderWindow() }
        refresh()
        startUpdateChecks()
    }

    // A hotkey that silently stops working after a reboot is the one way this app can feel
    // broken, so it starts as a login item once. Only from /Applications: a login item
    // registered from a build folder would point at a path that later disappears.
    private func enableLoginItemOnFirstRun() {
        guard !AppSettings.loginItemOffered, Updater.isInstalled else { return }
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
        autoUpdateItem.target = self
        autoUpdateItem.state = AppSettings.autoUpdate ? .on : .off
        menu.addItem(autoUpdateItem)
        checkUpdatesItem.target = self
        menu.addItem(checkUpdatesItem)
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

    // CmdE runs for weeks at a time as a login item, so checking only at launch would never
    // find anything. The hourly tick is just a retry for sleep and being offline: a real check
    // happens once a day, and only a successful one counts.
    private func startUpdateChecks() {
        guard Updater.isInstalled else { return }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
        Task { await checkIfDue() }
    }

    private func checkIfDue() async {
        if let last = AppSettings.lastUpdateCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
        await runUpdateCheck(userInitiated: false)
    }

    @objc private func checkForUpdates() {
        Task { await runUpdateCheck(userInitiated: true) }
    }

    @objc private func toggleAutoUpdate() {
        AppSettings.autoUpdate = autoUpdateItem.state != .on
        autoUpdateItem.state = AppSettings.autoUpdate ? .on : .off
    }

    // The background path never shows an alert, since this can fire in the middle of a game. A
    // failed background check looks the same as being up to date; with automatic installs off,
    // a new version only shows up as the menu item's title.
    private func runUpdateCheck(userInitiated: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        do {
            let update = try await Updater.latestRelease()
            AppSettings.lastUpdateCheck = Date()

            guard Updater.isNewer(update.version) else {
                checkUpdatesItem.title = "Check for Updates…"
                if userInitiated { showAlert("You're up to date", "CmdE \(Updater.currentVersion) is the latest version.") }
                return
            }
            if userInitiated {
                guard confirmUpdate(update) else { return }
            } else if !AppSettings.autoUpdate {
                checkUpdatesItem.title = "Update to \(update.version)…"
                return
            }

            try await Updater.install(update)
            relaunch()
        } catch {
            if userInitiated { showAlert("Couldn't update CmdE", error.localizedDescription) }
        }
    }

    private func confirmUpdate(_ update: AppUpdate) -> Bool {
        let alert = NSAlert()
        alert.messageText = "CmdE \(update.version) is available"
        alert.informativeText = update.notes.isEmpty ? "You're on \(Updater.currentVersion)." : String(update.notes.prefix(500))
        alert.addButton(withTitle: "Update & Relaunch")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // ⌘E has to be released first: the new copy starts while this one is still running, and only
    // one process can hold a hotkey, so it would come up reporting ⌘E as taken.
    private func relaunch() {
        hotKey.unregister()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if error == nil {
                    NSApp.terminate(nil)
                } else {
                    self.refresh()
                }
            }
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
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
