import Cocoa
import Carbon
import ScreenCaptureKit
import AVFoundation

// MARK: - Screen Capture Manager

class CaptureManager: NSObject, SCStreamDelegate, SCStreamOutput {
    let videoLayer = AVSampleBufferDisplayLayer()
    private var stream: SCStream?
    private var width = 0
    private var height = 0
    private var paused = false
    var capturing = false
    var onError: (() -> Void)?

    func startCapture(window: SCWindow) async throws {
        if stream != nil { return }
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.capturesAudio = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)

        let filter = SCContentFilter(desktopIndependentWindow: window)
        if #available(macOS 14, *) {
            width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        } else {
            width = Int(window.frame.width * 2)
            height = Int(window.frame.height * 2)
        }
        config.width = width
        config.height = height

        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global())
        try await stream?.startCapture()
        capturing = true
    }

    func stopCapture() {
        guard let s = stream else { return }
        s.stopCapture { _ in }
        stream = nil
        capturing = false
    }

    func updateCaptureSize(width: Int, height: Int) {
        self.width = width
        self.height = height
        applyConfiguration()
    }

    /// Slows the stream to near-idle while the mirror is hidden behind the
    /// focused real window, instead of leaving it at 60fps with nothing on
    /// screen to show the output. Keeping the stream alive rather than
    /// stopping it avoids the restart latency of a fresh `startCapture`
    /// when the mirror reappears.
    func setPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
        applyConfiguration()
    }

    private func applyConfiguration() {
        guard let s = stream else { return }
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.capturesAudio = false
        config.minimumFrameInterval = paused ? CMTime(value: 1, timescale: 2) : CMTime(value: 1, timescale: 60)
        config.width = width
        config.height = height
        s.updateConfiguration(config) { err in
            if let err = err { print("[warn] updateConfig: \(err)") }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid, outputType == .screen else { return }
        // SCK delivers idle/blank frames on every tick even when the window hasn't
        // changed; skip anything that isn't a fully rendered frame.
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue),
              status == .complete else { return }

        DispatchQueue.main.async {
            if #available(macOS 15, *) {
                self.videoLayer.sampleBufferRenderer.enqueue(sampleBuffer)
            } else {
                self.videoLayer.enqueue(sampleBuffer)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[warn] capture stopped: \(error)")
        DispatchQueue.main.async {
            self.stream = nil
            self.capturing = false
            self.onError?()
        }
    }
}

// MARK: - Coordinate Transform

func cgToNS(_ cgRect: CGRect) -> NSRect {
    guard let main = NSScreen.screens.first else { return cgRect }
    return NSRect(x: cgRect.origin.x,
                  y: main.frame.height - cgRect.origin.y - cgRect.height,
                  width: cgRect.width, height: cgRect.height)
}

// MARK: - Private API: _AXUIElementGetWindow

private let _AXUIElementGetWindow: @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError = {
    let handle = dlopen(nil, RTLD_NOW)!
    return unsafeBitCast(dlsym(handle, "_AXUIElementGetWindow"),
                         to: (@convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError).self)
}()

// MARK: - Mirror Panel

class MirrorPanel {
    let scWindow: SCWindow
    let capture = CaptureManager()
    var panel: NSPanel!
    private var axApp: AXUIElement?
    private var axObserver: AXObserver?
    private var aliveTimer: Timer?
    private var clickMonitor: Any?
    private var resizeDebounce: DispatchWorkItem?
    private var realWindowFocused = false
    private var stopped = false

    /// Polls at `hiddenFocusPollInterval` while the mirror is hidden, and
    /// `visiblePollInterval` otherwise. This is a backstop for a missed AX
    /// notification, so it only needs to run fast while the mirror is
    /// hidden — that is the state where a missed notification leaves the
    /// real window uncovered with nothing showing on top of it.
    private static let hiddenFocusPollInterval: TimeInterval = 0.25
    private static let visiblePollInterval: TimeInterval = 1.0

    init(scWindow: SCWindow) {
        self.scWindow = scWindow

        let nsFrame = cgToNS(scWindow.frame)
        panel = NSPanel(contentRect: nsFrame,
                        styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isOpaque = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        // Default fade animation overlaps a hide with the next show when they
        // happen within a fraction of a second, leaving a double image.
        panel.animationBehavior = .none

        let view = NSView(frame: NSRect(origin: .zero, size: nsFrame.size))
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true

        let videoLayer = capture.videoLayer
        videoLayer.frame = view.bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(videoLayer)

        panel.contentView = view

        capture.onError = { [weak self] in
            guard let self else { return }
            self.stop()
            PinManager.shared.unpinByWindowID(self.scWindow.windowID)
        }
    }

    @MainActor
    func start() async {
        panel.makeKeyAndOrderFront(nil)
        do {
            try await capture.startCapture(window: scWindow)
        } catch {
            print("[error] capture failed: \(error)")
            stop()
            return
        }
        guard !stopped else { return }
        startAXObserver()
        startClickMonitor()
        updateFocusState()
    }

    func stop() {
        stopped = true
        aliveTimer?.invalidate()
        aliveTimer = nil
        resizeDebounce?.cancel()
        resizeDebounce = nil
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(obs),
                                  .defaultMode)
        }
        axObserver = nil
        axApp = nil
        capture.stopCapture()
        panel.close()
    }

    private func startAXObserver() {
        guard let pid = scWindow.owningApplication?.processID else { return }

        let axApp = AXUIElementCreateApplication(pid_t(pid))
        AXUIElementSetMessagingTimeout(axApp, 0.1)
        self.axApp = axApp
        // Even if the window itself can't be found (e.g. its AX window list
        // hasn't caught up yet), the app-level notifications below still
        // register — they key off axApp, not axWin.
        let axWin = findAXWindow(axApp: axApp)
        if axWin == nil {
            print("[warn] cannot find AX window for observer; move/resize sync and focus hiding fall back to the poll")
        }

        typealias Callback = @convention(c) (AXObserver, AXUIElement, CFString, UnsafeMutableRawPointer?) -> Void
        let cb: Callback = { _, _, name, ptr in
            guard let ptr else { return }
            let mirror = Unmanaged<MirrorPanel>.fromOpaque(ptr).takeUnretainedValue()
            DispatchQueue.main.async { mirror.handleAXNotification(name as String) }
        }

        var obs: AXObserver?
        guard AXObserverCreate(pid_t(pid), cb, &obs) == .success, let observer = obs else { return }

        let ptr = Unmanaged.passUnretained(self).toOpaque()
        if let axWin {
            addAXNotification(observer, axWin, kAXWindowMovedNotification, ptr)
            addAXNotification(observer, axWin, kAXWindowResizedNotification, ptr)
        }
        addAXNotification(observer, axApp, kAXApplicationActivatedNotification, ptr)
        addAXNotification(observer, axApp, kAXApplicationDeactivatedNotification, ptr)
        addAXNotification(observer, axApp, kAXFocusedWindowChangedNotification, ptr)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
    }

    private func addAXNotification(_ observer: AXObserver, _ element: AXUIElement, _ name: String, _ ptr: UnsafeMutableRawPointer) {
        let result = AXObserverAddNotification(observer, element, name as CFString, ptr)
        if result != .success {
            print("[warn] AXObserverAddNotification(\(name)) failed: \(result)")
        }
    }

    private func handleAXNotification(_ name: String) {
        guard !stopped else { return }
        switch name {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            syncFrame()
        default:
            // Routes through checkAlive() rather than calling updateFocusState()
            // directly, so a focus event that arrives after the pinned window
            // has closed unpins it instead of re-showing a mirror of nothing.
            checkAlive()
        }
    }

    private func findAXWindow(axApp: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return nil }

        for win in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(win, &wid) == .success, wid == scWindow.windowID {
                return win
            }
        }
        return nil
    }

    func syncFrame() {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], scWindow.windowID) as? [[String: Any]],
              let first = info.first,
              let bounds = first[kCGWindowBounds as String] as? [String: CGFloat] else { return }

        let cgFrame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                             width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        let nsFrame = cgToNS(cgFrame)

        if panel.frame.size != nsFrame.size {
            // A resize drag fires this on every AX notification; debounce so we don't
            // reconfigure the stream dozens of times over the course of one drag.
            resizeDebounce?.cancel()
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let width = Int(nsFrame.width * scale)
            let height = Int(nsFrame.height * scale)
            let work = DispatchWorkItem { [weak self] in
                self?.capture.updateCaptureSize(width: width, height: height)
            }
            resizeDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        if panel.frame != nsFrame {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.setFrame(nsFrame, display: true)
            CATransaction.commit()
        }
    }

    private func scheduleAliveCheck() {
        aliveTimer?.invalidate()
        let interval = realWindowFocused ? Self.hiddenFocusPollInterval : Self.visiblePollInterval
        aliveTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.checkAlive()
        }
    }

    private func checkAlive() {
        let exists = CGWindowListCopyWindowInfo([.optionIncludingWindow], scWindow.windowID) as? [[String: Any]]
        if exists?.isEmpty ?? true {
            PinManager.shared.unpinByWindowID(scWindow.windowID)
            return
        }
        updateFocusState()
    }

    /// True when the real window, not just its app, holds focus. Checking
    /// the app alone would keep the mirror hidden for an unfocused sibling
    /// window of the same app.
    private func isRealWindowFocused() -> Bool {
        guard let pid = scWindow.owningApplication?.processID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(pid),
              let axApp else { return false }

        var ref: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref)
        guard status == .success, let focusedWin = ref else {
            // A busy or beach-balling app returns .cannotComplete transiently;
            // treat that as "unchanged" instead of "not focused" so a hiccup
            // doesn't flash the mirror over the window the user is using.
            return status == .cannotComplete ? realWindowFocused : false
        }

        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(focusedWin as! AXUIElement, &wid) == .success && wid == scWindow.windowID
    }

    private func updateFocusState() {
        let focused = isRealWindowFocused()
        if focused != realWindowFocused {
            realWindowFocused = focused
            if focused {
                capture.setPaused(true)
                panel.orderOut(nil)
                print("[info] mirror hidden, real window focused (window \(scWindow.windowID))")
            } else {
                capture.setPaused(false)
                syncFrame()
                panel.orderFrontRegardless()
                print("[info] mirror shown, real window lost focus (window \(scWindow.windowID))")
            }
        }
        // Rearm at the interval for the state we just settled on, so a
        // flip (from here or from an AX notification) takes effect on the
        // next tick instead of waiting out whatever interval was already
        // in flight.
        scheduleAliveCheck()
    }

    private func startClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return }
            let mouseLocation = NSEvent.mouseLocation
            if panel.frame.contains(mouseLocation) {
                self.activateRealWindow()
            }
        }
    }

    private func activateRealWindow() {
        guard let bundleID = scWindow.owningApplication?.bundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
        app.activate()
        // Also raise the specific window via Accessibility
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        if let axWin = findAXWindow(axApp: axApp) {
            AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
        }
    }
}

// MARK: - Pin Manager

class PinManager {
    static let shared = PinManager()
    var mirrors: [MirrorPanel] = []
    var onPinChanged: (() -> Void)?

    // Pin the frontmost window of the frontmost app
    func pinFrontmost() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            print("[warn] no frontmost app to pin")
            return
        }
        pinApp(pid: frontApp.processIdentifier, name: frontApp.localizedName ?? "?")
    }

    // Pin by app name (for CLI usage)
    func pinByName(_ appName: String) {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
        }
        guard let app = apps.first else {
            print("No running app matching '\(appName)'.")
            return
        }
        pinApp(pid: app.processIdentifier, name: app.localizedName ?? appName)
    }

    func unpinByName(_ appName: String) {
        let matching = mirrors.filter {
            $0.scWindow.owningApplication?.applicationName.localizedCaseInsensitiveContains(appName) == true
        }
        if matching.isEmpty {
            print("No pinned window matching '\(appName)'.")
            return
        }
        for m in matching {
            let name = m.scWindow.owningApplication?.applicationName ?? "?"
            mirrors.removeAll { $0.scWindow.windowID == m.scWindow.windowID }
            m.stop()
            print("Unpinned '\(name)' (window \(m.scWindow.windowID))")
            showHUD("📍 \(name)")
        }
        onPinChanged?()
    }

    func unpinByWindowID(_ windowID: CGWindowID) {
        guard let idx = mirrors.firstIndex(where: { $0.scWindow.windowID == windowID }) else { return }
        let m = mirrors.remove(at: idx)
        let name = m.scWindow.owningApplication?.applicationName ?? "?"
        m.stop()
        print("Auto-unpinned '\(name)'")
        onPinChanged?()
    }

    func unpinLast() {
        guard let m = mirrors.last else {
            print("Nothing pinned.")
            return
        }
        let name = m.scWindow.owningApplication?.applicationName ?? "?"
        mirrors.removeLast()
        m.stop()
        print("Unpinned '\(name)'")
        showHUD("📍 \(name)")
        onPinChanged?()
    }

    func unpinAll() {
        if mirrors.isEmpty {
            print("Nothing pinned.")
            return
        }
        mirrors.forEach { $0.stop() }
        let count = mirrors.count
        mirrors.removeAll()
        print("Unpinned all (\(count) windows)")
        showHUD("📍 All unpinned")
        onPinChanged?()
    }

    func listPinned() {
        if mirrors.isEmpty {
            print("No pinned windows.")
            return
        }
        print("Pinned windows:")
        for m in mirrors {
            let name = m.scWindow.owningApplication?.applicationName ?? "?"
            print("  📌 \(name) (window \(m.scWindow.windowID))")
        }
    }

    // List all visible windows (for discovery)
    func listWindows(filter: String?) {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            print("Cannot get window list.")
            return
        }

        func pad(_ s: String, _ w: Int) -> String {
            s.count >= w ? String(s.prefix(w)) : s + String(repeating: " ", count: w - s.count)
        }

        var rows: [(id: Int, owner: String, name: String)] = []
        for w in windowList {
            guard let wid = w[kCGWindowNumber as String] as? Int,
                  let owner = w[kCGWindowOwnerName as String] as? String else { continue }
            if let bounds = w[kCGWindowBounds as String] as? [String: Any] {
                let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
                let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
                if width < 50 || height < 50 { continue }
            }
            let name = w[kCGWindowName as String] as? String ?? "(untitled)"
            if let filter, !owner.localizedCaseInsensitiveContains(filter) { continue }
            rows.append((id: wid, owner: owner, name: name))
        }

        if rows.isEmpty {
            print("No windows found\(filter.map { " for '\($0)'" } ?? "").")
            return
        }

        print("\(pad("ID", 8))  \(pad("App", 22))  Window Title")
        print(String(repeating: "─", count: 65))
        for r in rows {
            print("\(pad("\(r.id)", 8))  \(pad(r.owner, 22))  \(String(r.name.prefix(32)))")
        }
    }

    /// Returns running apps that have visible windows, excluding ourselves and system agents.
    func runningAppsWithWindows() -> [NSRunningApplication] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        // Collect PIDs that have at least one visible window of reasonable size
        var pidsWithWindows = Set<pid_t>()
        for w in windowList {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if let bounds = w[kCGWindowBounds as String] as? [String: Any] {
                let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
                let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
                if width < 50 || height < 50 { continue }
            }
            pidsWithWindows.insert(pid)
        }

        return NSWorkspace.shared.runningApplications.filter { app in
            app.processIdentifier != myPID &&
            app.activationPolicy == .regular &&
            pidsWithWindows.contains(app.processIdentifier)
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    func isPinned(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return mirrors.contains { $0.scWindow.owningApplication?.bundleIdentifier == bundleID }
    }

    func pinApp(pid: pid_t, name: String) {
        guard let scWindow = findFrontWindow(pid: pid) else {
            print("[error] cannot find window for '\(name)' (pid \(pid))")
            return
        }

        if mirrors.contains(where: { $0.scWindow.windowID == scWindow.windowID }) {
            print("'\(name)' is already pinned.")
            return
        }

        let m = MirrorPanel(scWindow: scWindow)
        mirrors.append(m)
        Task { await m.start() }

        print("Pinned '\(name)' (window \(scWindow.windowID))")
        showHUD("📌 \(name)")
        onPinChanged?()
    }

    private func findFrontWindow(pid: pid_t) -> SCWindow? {
        let axApp = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        var axWindow: AXUIElement?

        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success, let w = ref {
            axWindow = (w as! AXUIElement)
        } else if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &ref) == .success, let w = ref {
            axWindow = (w as! AXUIElement)
        } else if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
                  let list = ref as? [AXUIElement], let first = list.first {
            axWindow = first
        }

        guard let axWin = axWindow else { return nil }

        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow(axWin, &windowID) == .success, windowID != 0 else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        var result: SCShareableContent?
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, _ in
            result = content
            semaphore.signal()
        }
        semaphore.wait()

        return result?.windows.first(where: { $0.windowID == windowID })
    }

    private func showHUD(_ text: String) {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 50),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = .screenSaver
        w.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        w.isOpaque = false
        w.hasShadow = true
        w.center()
        w.contentView?.wantsLayer = true
        w.contentView?.layer?.cornerRadius = 12

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.frame = w.contentView!.bounds
        label.autoresizingMask = [.width, .height]
        w.contentView?.addSubview(label)
        w.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { w.close() }
    }
}

// MARK: - Global Hotkeys

private var hotKeyRefs: [EventHotKeyRef?] = []

private func installHotkeys() {
    var sig: OSType = 0
    for c in "PINW".utf8 { sig = (sig << 8) | OSType(c) }

    let keys: [(keyCode: UInt32, modifiers: UInt32, id: UInt32)] = [
        (0x23, UInt32(optionKey), 1),   // Option+P = pin frontmost
        (0x20, UInt32(optionKey), 2),   // Option+U = unpin last
    ]

    for key in keys {
        let hkID = EventHotKeyID(signature: sig, id: key.id)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(key.keyCode, key.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        hotKeyRefs.append(ref)
    }

    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
        var hkID = EventHotKeyID()
        GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
        DispatchQueue.main.async {
            switch hkID.id {
            case 1: PinManager.shared.pinFrontmost()
            case 2: PinManager.shared.unpinLast()
            default: break
            }
        }
        return noErr
    }, 1, &spec, nil, nil)
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    let cliArgs: [String]

    init(cliArgs: [String]) {
        self.cliArgs = cliArgs
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // Request Accessibility
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)

        // Request Screen Recording
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { _, _ in }

        // Watch for app termination to auto-unpin
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { notif in
            if let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                let toRemove = PinManager.shared.mirrors.filter {
                    $0.scWindow.owningApplication?.bundleIdentifier == app.bundleIdentifier
                }
                toRemove.forEach { PinManager.shared.unpinByWindowID($0.scWindow.windowID) }
            }
        }

        // Handle CLI args or run as menu bar app
        if !cliArgs.isEmpty {
            handleCLI(cliArgs)
        } else {
            setupMenuBar()
            installHotkeys()
            print("PinWindow running. Option+P = pin, Option+U = unpin.")
        }
    }

    func handleCLI(_ args: [String]) {
        // For "list" command, no need to keep running
        switch args[0] {
        case "list":
            PinManager.shared.listWindows(filter: args.count > 1 ? args[1] : nil)
            NSApp.terminate(nil)

        case "pin":
            guard args.count > 1 else {
                printUsage()
                NSApp.terminate(nil)
                return
            }
            // Delay slightly to let permissions settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                PinManager.shared.pinByName(args[1])
            }

        case "unpin":
            if args.count > 1 {
                PinManager.shared.unpinByName(args[1])
            } else {
                PinManager.shared.unpinAll()
            }
            // Give time for cleanup
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }

        case "status":
            PinManager.shared.listPinned()
            NSApp.terminate(nil)

        default:
            printUsage()
            NSApp.terminate(nil)
        }
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarTitle()

        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu

        PinManager.shared.onPinChanged = { [weak self] in
            self?.updateMenuBarTitle()
        }
    }

    func updateMenuBarTitle() {
        let count = PinManager.shared.mirrors.count
        statusItem?.button?.title = count > 0 ? "📌 \(count)" : "📌"
    }

    @objc func pinAppAction(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? NSRunningApplication,
              let name = app.localizedName else { return }
        PinManager.shared.pinApp(pid: app.processIdentifier, name: name)
    }

    @objc func unpinAppAction(_ sender: NSMenuItem) {
        guard let windowID = sender.representedObject as? CGWindowID else { return }
        PinManager.shared.unpinByWindowID(windowID)
    }

    @objc func doUnpinAll() {
        PinManager.shared.unpinAll()
    }

    @objc func openSupportPage() {
        NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/justwyo")!)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let pm = PinManager.shared

        // --- Pinned section ---
        if !pm.mirrors.isEmpty {
            let header = NSMenuItem(title: "Pinned", action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.attributedTitle = NSAttributedString(
                string: "PINNED",
                attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                             .foregroundColor: NSColor.secondaryLabelColor])
            menu.addItem(header)

            for m in pm.mirrors {
                let appName = m.scWindow.owningApplication?.applicationName ?? "Unknown"

                // Get window title to differentiate multiple windows from the same app
                var title = appName
                if let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], m.scWindow.windowID) as? [[String: Any]],
                   let first = info.first,
                   let windowTitle = first[kCGWindowName as String] as? String,
                   !windowTitle.isEmpty {
                    title = "\(appName) — \(windowTitle)"
                }

                let item = NSMenuItem(title: title, action: #selector(unpinAppAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = m.scWindow.windowID

                if let bid = m.scWindow.owningApplication?.bundleIdentifier,
                   let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
                   let icon = runningApp.icon {
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                }

                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // --- Available apps section ---
        let appsHeader = NSMenuItem(title: "Pin App", action: nil, keyEquivalent: "")
        appsHeader.isEnabled = false
        appsHeader.attributedTitle = NSAttributedString(
            string: "PIN AN APP",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: NSColor.secondaryLabelColor])
        menu.addItem(appsHeader)

        let apps = pm.runningAppsWithWindows()
        for app in apps {
            guard let name = app.localizedName else { continue }

            let item = NSMenuItem(title: name, action: #selector(pinAppAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app

            if let icon = app.icon {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }

            menu.addItem(item)
        }

        if apps.isEmpty {
            let noApps = NSMenuItem(title: "No apps with windows", action: nil, keyEquivalent: "")
            noApps.isEnabled = false
            menu.addItem(noApps)
        }

        // --- Footer ---
        menu.addItem(.separator())

        let hotkeys = NSMenuItem(title: "⌥P Pin frontmost  ·  ⌥U Unpin last", action: nil, keyEquivalent: "")
        hotkeys.isEnabled = false
        hotkeys.attributedTitle = NSAttributedString(
            string: "⌥P Pin frontmost  ·  ⌥U Unpin last",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.tertiaryLabelColor])
        menu.addItem(hotkeys)

        if !pm.mirrors.isEmpty {
            let unpinAll = NSMenuItem(title: "Unpin All", action: #selector(doUnpinAll), keyEquivalent: "")
            unpinAll.target = self
            menu.addItem(unpinAll)
        }

        menu.addItem(.separator())

        let support = NSMenuItem(title: "Support PinWindow...", action: #selector(openSupportPage), keyEquivalent: "")
        support.target = self
        menu.addItem(support)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit PinWindow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}

// MARK: - Usage

func printUsage() {
    print("""
    PinWindow - Keep any window always on top

    Usage:
      PinWindow                     Run as menu bar app (Option+P/U hotkeys)
      PinWindow pin <app>           Pin an app's frontmost window
      PinWindow unpin [app]         Unpin app (or all if no app given)
      PinWindow list [app]          List visible windows
      PinWindow status              Show currently pinned windows

    Hotkeys (when running as menu bar app):
      Option+P    Pin the frontmost window
      Option+U    Unpin the last pinned window

    How it works:
      Uses ScreenCaptureKit to mirror the target window into a floating
      overlay panel. The overlay passes all mouse events through to the
      real window underneath. The overlay hides itself while the real
      window has focus, and shows again when focus moves elsewhere.

    Permissions required:
      - Screen Recording  (System Settings > Privacy & Security > Screen Recording)
      - Accessibility      (System Settings > Privacy & Security > Accessibility)
    """)
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let cliArgs = Array(CommandLine.arguments.dropFirst())
let delegate = AppDelegate(cliArgs: cliArgs)
app.delegate = delegate
app.run()
