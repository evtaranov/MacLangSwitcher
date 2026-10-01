import Cocoa
import Carbon
import ServiceManagement

// MARK: - Input sources

enum InputSources {
    static func selectable() -> [TISInputSource] {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
            kTISPropertyInputSourceIsEnabled as String: true,
        ] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        // Only real keyboard layouts / input methods, skip palettes etc.
        return list.filter { src in
            let type = property(src, kTISPropertyInputSourceType) as String?
            return type == (kTISTypeKeyboardLayout as String) || type == (kTISTypeKeyboardInputMode as String)
        }
    }

    static func current() -> TISInputSource {
        TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    }

    static func id(_ src: TISInputSource) -> String {
        property(src, kTISPropertyInputSourceID) ?? ""
    }

    static func name(_ src: TISInputSource) -> String {
        property(src, kTISPropertyLocalizedName) ?? id(src)
    }

    static func shortLabel(_ src: TISInputSource) -> String {
        if let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) {
            let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String] ?? []
            if let first = langs.first {
                return String(first.prefix(2)).uppercased()
            }
        }
        return String(name(src).prefix(2)).uppercased()
    }

    static func selectNext() {
        let sources = selectable()
        guard sources.count > 1 else { return }
        let currentID = id(current())
        let idx = sources.firstIndex { id($0) == currentID } ?? -1
        let next = sources[(idx + 1) % sources.count]
        TISSelectInputSource(next)
    }

    private static func property<T>(_ src: TISInputSource, _ key: CFString) -> T? {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue() as? T
    }
}

// MARK: - Cmd+Shift detector

/// Fires when Cmd+Shift are pressed together and released without any other key or click in between.
final class HotkeyMonitor {
    var onTrigger: (() -> Void)?
    var enabled = true

    private var tap: CFMachPort?
    private var armed = false

    func start() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            armed = false
        case .flagsChanged:
            let flags = event.flags
            let cmd = flags.contains(.maskCommand)
            let shift = flags.contains(.maskShift)
            let others = flags.contains(.maskControl) || flags.contains(.maskAlternate)
            if cmd && shift && !others {
                armed = true
            } else if others {
                armed = false
            } else if armed && !cmd && !shift {
                // Both released -> trigger
                armed = false
                if enabled { onTrigger?() }
            }
        default:
            // Any key or click while holding Cmd+Shift means it was a regular shortcut (e.g. Cmd+Shift+Z).
            armed = false
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor = HotkeyMonitor()
    private let menu = NSMenu()
    private var retryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        statusItem.menu = menu
        updateTitle()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        monitor.enabled = !UserDefaults.standard.bool(forKey: "disabled")
        monitor.onTrigger = { InputSources.selectNext() }
        startMonitor()
    }

    private func startMonitor() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if trusted && monitor.start() {
            retryTimer?.invalidate()
            retryTimer = nil
            updateTitle()
            return
        }
        updateTitle()
        // Wait until the user grants Accessibility permission.
        if retryTimer == nil {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                if AXIsProcessTrusted() && self.monitor.start() {
                    self.retryTimer?.invalidate()
                    self.retryTimer = nil
                    self.updateTitle()
                }
            }
        }
    }

    @objc private func inputSourceChanged() {
        DispatchQueue.main.async { self.updateTitle() }
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let label = InputSources.shortLabel(InputSources.current())
        let hasPermission = retryTimer == nil
        button.title = hasPermission ? label : "\(label) ⚠︎"
        button.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        button.alphaValue = monitor.enabled ? 1.0 : 0.5
        button.toolTip = "Lang Switch — press ⌘⇧ to switch input source"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let currentID = InputSources.id(InputSources.current())
        for src in InputSources.selectable() {
            let item = NSMenuItem(title: InputSources.name(src), action: #selector(selectSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = src
            item.state = InputSources.id(src) == currentID ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        if retryTimer != nil {
            let warn = NSMenuItem(title: "Grant Accessibility access…", action: #selector(openAccessibility), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let toggle = NSMenuItem(title: "Switch with ⌘⇧", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = monitor.enabled ? .on : .off
        menu.addItem(toggle)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func selectSource(_ sender: NSMenuItem) {
        guard let obj = sender.representedObject else { return }
        TISSelectInputSource((obj as! TISInputSource))
    }

    @objc private func toggleEnabled() {
        monitor.enabled.toggle()
        UserDefaults.standard.set(!monitor.enabled, forKey: "disabled")
        updateTitle()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
