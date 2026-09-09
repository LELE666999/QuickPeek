@preconcurrency import AppKit
import SwiftUI
import Carbon.HIToolbox
@preconcurrency import ApplicationServices
@preconcurrency import CoreFoundation
import AVFoundation
import SDWebImage
import SDWebImageWebPCoder
import os.lock
import ImageIO
import Foundation

// Thread-safe shared state for the CGEvent tap callback
// CGEvent tap runs on the RunLoop thread, not necessarily MainActor,
// so we need lock-protected state the callback can read safely.
final class TapSharedState: @unchecked Sendable {
    static let shared = TapSharedState()
    private let lock = OSAllocatedUnfairLock(initialState: State())

    struct State {
        var timelineEditing = false
        var previewVisible = false
        var previewPinned = false
        var canPreviewSelection = false
        var eventTap: CFMachPort?
    }

    var previewVisible: Bool {
        get { lock.withLock { $0.previewVisible } }
        set { lock.withLock { $0.previewVisible = newValue } }
    }

    var timelineEditing: Bool {
        get { lock.withLock { $0.timelineEditing } }
        set { lock.withLock { $0.timelineEditing = newValue } }
    }

    var canPreviewSelection: Bool {
        get { lock.withLock { $0.canPreviewSelection } }
        set { lock.withLock { $0.canPreviewSelection = newValue } }
    }

    var previewPinned: Bool {
        get { lock.withLock { $0.previewPinned } }
        set { lock.withLock { $0.previewPinned = newValue } }
    }

    var eventTap: CFMachPort? {
        get { lock.withLock { $0.eventTap } }
        set { lock.withLock { $0.eventTap = newValue } }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!

    private var previewPanel: NSPanel?
    private var pinnedPanels: [NSPanel] = []
    private var settingsWindow: NSWindow?
    private var previewVisible = false {
        didSet { TapSharedState.shared.previewVisible = previewVisible }
    }
    private var isAnimating = false
    private var runLoopSource: CFRunLoopSource?
    private var currentSelectionURLs: [URL] = []
    private var cachedSelectionURLs: [URL] = []
    private var finderScript: NSAppleScript?
    private var selectionPollTimer: Timer?
    private var selectionContextTimer: Timer?
    private var eventTapHealthTimer: Timer?
    private var previewPinned = false
    private var globalArrowMonitor: Any?
    private var localArrowMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)
        setupStatusBar()
        warmUpAppleScript()
        startSelectionContextMonitoring()
        setupArrowKeyMonitors()
        requestAccessibilityAndSetup()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty, !TapSharedState.shared.timelineEditing else { return }
        currentSelectionURLs = files
        isAnimating = false
        showPreview(for: files)
        // A directly opened file is independent of Finder's current selection.
        stopSelectionPolling()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopSelectionContextMonitoring()
        stopEventTapHealthMonitoring()
        removeEventTap()
        removeArrowKeyMonitors()
    }

    // MARK: - Accessibility + CGEvent Tap

    private func requestAccessibilityAndSetup() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let trusted = AXIsProcessTrustedWithOptions(
            [promptKey: true] as CFDictionary
        )
        if trusted {
            setupEventTap()
        } else {
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    DispatchQueue.main.async { self?.setupEventTap() }
                }
            }
        }
        startEventTapHealthMonitoring()
        updateMenu()
    }

    func setupEventTap() {
        removeEventTap()

        // The callback is a C function pointer — must not capture self.
        // We pass a reference to AppDelegate via userInfo (refcon).
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue)
                | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
                | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue),
            callback: spaceKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = tap else {
            NSLog("QuickPeek: CGEvent tap creation failed — falling back to NSEvent monitors")
            setupFallbackMonitors()
            return
        }

        TapSharedState.shared.eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("QuickPeek: CGEvent tap installed successfully")
        updateMenu()
    }

    private func removeEventTap() {
        if let tap = TapSharedState.shared.eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        TapSharedState.shared.eventTap = nil
        runLoopSource = nil
    }

    private func startEventTapHealthMonitoring() {
        stopEventTapHealthMonitoring()
        eventTapHealthTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.repairEventTapIfNeeded()
        }
    }

    private func stopEventTapHealthMonitoring() {
        eventTapHealthTimer?.invalidate()
        eventTapHealthTimer = nil
    }

    private func repairEventTapIfNeeded() {
        guard AXIsProcessTrusted() else {
            removeEventTap()
            updateMenu()
            return
        }

        guard let tap = TapSharedState.shared.eventTap else {
            NSLog("QuickPeek: event tap missing, reinstalling")
            setupEventTap()
            return
        }

        if !CFMachPortIsValid(tap) {
            NSLog("QuickPeek: event tap invalid, reinstalling")
            setupEventTap()
        } else if !CGEvent.tapIsEnabled(tap: tap) {
            NSLog("QuickPeek: event tap disabled, re-enabling")
            CGEvent.tapEnable(tap: tap, enable: true)
            updateMenu()
        }
    }

    // MARK: - Fallback NSEvent Monitors

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private func setupFallbackMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Space),
                  event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty else { return }
            self?.handleSpaceDown()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Space),
                  event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty else { return event }
            if TapSharedState.shared.timelineEditing { return event }
            let hadPreview = ((self?.previewVisible == true) && (self?.previewPinned == false))
                || self?.canHandleSpaceForCurrentContext() == true
            self?.handleSpaceDown()
            return hadPreview ? nil : event
        }
    }

    private func setupArrowKeyMonitors() {
        removeArrowKeyMonitors()
        globalArrowMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleArrowKey(event)
        }
        localArrowMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleArrowKey(event)
            return event
        }
    }

    private func removeArrowKeyMonitors() {
        if let monitor = globalArrowMonitor {
            NSEvent.removeMonitor(monitor)
            globalArrowMonitor = nil
        }
        if let monitor = localArrowMonitor {
            NSEvent.removeMonitor(monitor)
            localArrowMonitor = nil
        }
    }

    private func handleArrowKey(_ event: NSEvent) {
        guard !TapSharedState.shared.timelineEditing else { return }
        guard previewVisible, !previewPinned else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
        let arrowKeys: Set<UInt16> = [UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow), UInt16(kVK_UpArrow), UInt16(kVK_DownArrow)]
        guard arrowKeys.contains(event.keyCode) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.checkFinderSelectionChanged()
        }
    }

    // MARK: - Called from CGEvent tap (on main thread via RunLoop)

    func handleSpaceDown() {
        guard !TapSharedState.shared.timelineEditing else { return }
        if previewVisible {
            guard !previewPinned else { return }
            dismissPreview()
        } else {
            togglePreview()
        }
    }

    func setPreviewPinned(_ pinned: Bool) {
        previewPinned = pinned
        TapSharedState.shared.previewPinned = pinned
        if pinned {
            stopSelectionPolling()
            detachPinnedPreviewPanel()
        } else if previewVisible {
            startSelectionPolling()
            checkFinderSelectionChanged()
            reactivateFinderForNavigation()
        }
    }

    // MARK: - AppleScript

    private func warmUpAppleScript() {
        let source = """
        tell application "Finder"
            set theSelection to selection as alias list
            if (count of theSelection) > 0 then
                set outputText to ""
                repeat with selectedItem in theSelection
                    set outputText to outputText & POSIX path of selectedItem & linefeed
                end repeat
                return outputText
            end if
        end tell
        """
        let script = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        script?.compileAndReturnError(&errorInfo)
        finderScript = script
        cachedSelectionURLs = getFinderSelectionURLs()
        TapSharedState.shared.canPreviewSelection = !cachedSelectionURLs.isEmpty
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var err: NSDictionary?
            _ = self?.finderScript?.executeAndReturnError(&err)
        }
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let img = NSImage(named: "MenuIcon") {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = true
                button.image = img
            } else {
                button.image = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: "QuickPeek")
            }
        }
        updateMenu()
    }

    func updateMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "QuickPeek v1.0", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let tapHealthy = AXIsProcessTrusted()
            && TapSharedState.shared.eventTap.map { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap: $0) } == true
        let monitorItem = NSMenuItem(title: tapHealthy ? "快捷键: 空格（监听正常）" : "快捷键: 空格（需要修复权限/监听）", action: nil, keyEquivalent: "")
        monitorItem.isEnabled = false
        menu.addItem(monitorItem)
        menu.addItem(NSMenuItem.separator())

        let repairItem = NSMenuItem(title: "重新安装快捷键监听", action: #selector(reinstallShortcutMonitor), keyEquivalent: "")
        repairItem.target = self
        menu.addItem(repairItem)
        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self; menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())

        let hintItem = NSMenuItem(title: "Finder 中选文件按空格键预览", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false; menu.addItem(hintItem)
        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 QuickPeek", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; menu.addItem(quitItem)
        statusItem.menu = menu
    }

    // MARK: - Preview Toggle

    private func stopCurrentPreviewPlayback() {
        NotificationCenter.default.post(name: .quickPeekStopPlayback, object: nil)
    }

    func togglePreview() {
        guard !isAnimating else { return }
        if previewVisible {
            dismissPreview()
            return
        }
        guard let fileURLs = currentPreviewCandidateURLs() else { return }
        currentSelectionURLs = fileURLs
        showPreview(for: fileURLs)
    }

    private func dismissPreview(reactivateFinder: Bool = true) {
        stopSelectionPolling()
        guard let panel = previewPanel else { previewVisible = false; return }
        stopCurrentPreviewPlayback()
        isAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.insetBy(dx: 30, dy: 20), display: true)
        }, completionHandler: { [weak self] in
            guard let self, self.previewPanel === panel else { return }
            panel.close()
            self.previewPanel = nil
            self.previewVisible = false
            self.previewPinned = false
            TapSharedState.shared.previewPinned = false
            self.isAnimating = false
            self.refreshSelectionContext()
            if reactivateFinder,
               let finder = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) {
                finder.activate()
            }
        })
    }

    private func detachPinnedPreviewPanel() {
        guard let panel = previewPanel else { return }
        previewPanel = nil
        previewVisible = false
        previewPinned = false
        TapSharedState.shared.previewPinned = false
        isAnimating = false
        currentSelectionURLs = []
        cachedSelectionURLs = getFinderSelectionURLs()
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.orderFrontRegardless()
        if !pinnedPanels.contains(where: { $0 === panel }) {
            pinnedPanels.append(panel)
        }
        refreshSelectionContext()
        reactivateFinderForNavigation()
    }

    // MARK: - Finder Selection Polling

    private func startSelectionPolling() {
        stopSelectionPolling()
        selectionPollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.checkFinderSelectionChanged()
        }
    }

    private func stopSelectionPolling() {
        selectionPollTimer?.invalidate()
        selectionPollTimer = nil
    }

    /// Called by timer or arrow key events to check if Finder selection changed
    func checkFinderSelectionChanged() {
        guard !TapSharedState.shared.timelineEditing else { return }
        guard previewVisible, !previewPinned else { return }
        let newURLs = getFinderSelectionURLs()
        guard !newURLs.isEmpty else { return }
        guard newURLs.map(\.path) != currentSelectionURLs.map(\.path) else { return }
        cachedSelectionURLs = newURLs
        TapSharedState.shared.canPreviewSelection = true
        currentSelectionURLs = newURLs
        stopCurrentPreviewPlayback()
        // Replace preview content in-place
        guard let panel = previewPanel else { return }
        let previewView = makePreviewRootView(for: newURLs)
        panel.title = previewTitle(for: newURLs)
        panel.contentView = NSHostingView(rootView: previewView)
        // A new Finder selection must receive the same gesture focus as the
        // initial preview, rather than leaving the refreshed content inactive.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func startSelectionContextMonitoring() {
        stopSelectionContextMonitoring()
        refreshSelectionContext()
        selectionContextTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshSelectionContext()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFrontAppChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    private func stopSelectionContextMonitoring() {
        selectionContextTimer?.invalidate()
        selectionContextTimer = nil
        NotificationCenter.default.removeObserver(self, name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func handleFrontAppChanged() {
        refreshSelectionContext()
    }

    private func refreshSelectionContext() {
        guard !previewVisible else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else {
            cachedSelectionURLs = []
            TapSharedState.shared.canPreviewSelection = false
            return
        }
        guard !isFinderEditingText() else {
            cachedSelectionURLs = []
            TapSharedState.shared.canPreviewSelection = false
            return
        }

        let urls = getFinderSelectionURLs()
        cachedSelectionURLs = urls
        TapSharedState.shared.canPreviewSelection = !urls.isEmpty
    }

    private func currentPreviewCandidateURLs() -> [URL]? {
        guard canHandleSpaceForCurrentContext() else { return nil }
        if !cachedSelectionURLs.isEmpty,
           cachedSelectionURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
            return cachedSelectionURLs
        }
        let freshSelection = getFinderSelectionURLs()
        cachedSelectionURLs = freshSelection
        TapSharedState.shared.canPreviewSelection = !freshSelection.isEmpty
        return freshSelection
    }

    private func canHandleSpaceForCurrentContext() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return false }
        guard !isFinderEditingText() else { return false }
        return !cachedSelectionURLs.isEmpty || !getFinderSelectionURLs().isEmpty
    }

    private func isFinderEditingText() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier == "com.apple.finder" else { return false }
        let appRef = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedRaw: AnyObject?
        let focusErr = AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focusedRaw)
        guard focusErr == .success, let focused = focusedRaw else { return false }
        let focusedElement = focused as! AXUIElement
        var roleRaw: AnyObject?
        AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &roleRaw)
        guard let role = roleRaw as? String else { return false }
        return role == kAXTextFieldRole || role == kAXTextAreaRole
    }

    private func getFinderSelectionURLs() -> [URL] {
        var error: NSDictionary?
        if let result = finderScript?.executeAndReturnError(&error),
           error == nil,
           let output = result.stringValue {
            let urls = output
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { FileManager.default.fileExists(atPath: $0) }
                .map(URL.init(fileURLWithPath:))
            if !urls.isEmpty { return urls }
        }
        let source = """
        tell application "Finder"
            set theSelection to selection as alias list
            if (count of theSelection) > 0 then
                set outputText to ""
                repeat with selectedItem in theSelection
                    set outputText to outputText & POSIX path of selectedItem & linefeed
                end repeat
                return outputText
            end if
        end tell
        """
        let freshScript = NSAppleScript(source: source)
        var freshError: NSDictionary?
        if let result = freshScript?.executeAndReturnError(&freshError),
           freshError == nil,
           let output = result.stringValue {
            return output
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { FileManager.default.fileExists(atPath: $0) }
                .map(URL.init(fileURLWithPath:))
        }
        return []
    }


    private func showPreview(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let old = previewPanel {
            stopCurrentPreviewPlayback()
            old.close()
            previewPanel = nil
        }
        previewPinned = false
        TapSharedState.shared.previewPinned = false
        let previewView = makePreviewRootView(for: urls)
        let panelSize = preferredPanelSize(for: urls)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: panelSize.width, height: panelSize.height),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = previewTitle(for: urls)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.animationBehavior = .none
        if #available(macOS 11.0, *) {
            panel.titlebarSeparatorStyle = .none
        }
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: previewView)
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.drawsAsynchronously = true
        panel.contentView?.layer?.allowsEdgeAntialiasing = true
        if let frameView = panel.contentView?.superview {
            frameView.wantsLayer = true
            frameView.layer?.cornerRadius = 20
            frameView.layer?.masksToBounds = true
            frameView.layer?.borderWidth = 0
            frameView.layer?.backgroundColor = NSColor.clear.cgColor
            frameView.layer?.drawsAsynchronously = true
            frameView.layer?.allowsEdgeAntialiasing = true
        }
        adjustTrafficLightInsets(for: panel)
        panel.center()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let finalFrame = panel.frame
        let startFrame = finalFrame.insetBy(dx: 40, dy: 30)
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }
        previewPanel = panel
        previewVisible = true
        startSelectionPolling()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self, weak panel] in
            guard let self, let panel, self.previewPanel === panel, !self.previewPinned else { return }
            panel.isFloatingPanel = false
            panel.level = .normal
        }
        // Keep the preview key and the application active. Returning focus to
        // Finder here prevents trackpad gestures from reaching native preview views.
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === previewPanel || pinnedPanels.contains(where: { $0 === window }) {
            adjustTrafficLightInsets(for: window)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let index = pinnedPanels.firstIndex(where: { $0 === window }) {
            stopCurrentPreviewPlayback()
            pinnedPanels.remove(at: index)
            return
        }
        guard window === previewPanel else { return }
        stopCurrentPreviewPlayback()
        stopSelectionPolling()
        previewPanel = nil
        previewVisible = false
        isAnimating = false
        refreshSelectionContext()
    }

    private func reactivateFinderForNavigation() {
        guard !previewPinned,
              let finder = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            finder.activate()
        }
    }

    private func makePreviewRootView(for urls: [URL]) -> some View {
        Group {
            if urls.count == 1, let fileURL = urls.first {
                SingleFilePreviewContentView(
                    fileURL: fileURL,
                    isPinned: previewPinned,
                    onTogglePinned: { [weak self] pinned in self?.setPreviewPinned(pinned) },
                    onClose: { [weak self] in self?.dismissPreview() }
                )
            } else {
                MultiFilePreviewContentView(
                    fileURLs: urls,
                    isPinned: previewPinned,
                    onTogglePinned: { [weak self] pinned in self?.setPreviewPinned(pinned) },
                    onClose: { [weak self] in self?.dismissPreview() }
                )
            }
        }
    }

    private func previewTitle(for urls: [URL]) -> String {
        if urls.count == 1, let url = urls.first { return url.lastPathComponent }
        return "\(urls.count) 个项目"
    }

    private func preferredPanelSize(for urls: [URL]) -> CGSize {
        guard let url = urls.first else { return CGSize(width: 1180, height: 760) }
        if urls.count > 1 {
            let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let width = min(screenFrame.width * 0.96, 1460)
            let height = min(screenFrame.height * 0.92, 940)
            return CGSize(width: max(1120, width), height: max(760, height))
        }
        let defaultSize = CGSize(width: 1180, height: 760)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let chromeWidth: CGFloat = 290 + 20 + 20 + 18
        let chromeHeight: CGFloat = 148
        let maxContentWidth = min(screenFrame.width * 0.76, 1180)
        let maxContentHeight = min(screenFrame.height * 0.80, 880)

        let contentAspect = fastImageAspectRatio(for: url)

        guard let contentAspect else {
            return defaultSize
        }

        var contentWidth = min(maxContentWidth, max(620, maxContentHeight * contentAspect))
        var contentHeight = contentWidth / contentAspect

        if contentHeight > maxContentHeight {
            contentHeight = maxContentHeight
            contentWidth = contentHeight * contentAspect
        }

        let width = min(screenFrame.width * 0.96, max(1120, contentWidth + chromeWidth))
        let height = min(screenFrame.height * 0.92, max(760, contentHeight + chromeHeight))
        return CGSize(width: width, height: height)
    }

    private func adjustTrafficLightInsets(for window: NSWindow) {
        guard let closeButton = window.standardWindowButton(.closeButton),
              let miniButton = window.standardWindowButton(.miniaturizeButton),
              let zoomButton = window.standardWindowButton(.zoomButton),
              let container = closeButton.superview else {
            return
        }

        let topInset: CGFloat = 16
        let leadingInset: CGFloat = 18
        let spacing: CGFloat = 10
        let buttonSize = closeButton.frame.size
        let y = max(container.bounds.height - buttonSize.height - topInset, 0)

        closeButton.setFrameOrigin(NSPoint(x: leadingInset, y: y))
        miniButton.setFrameOrigin(NSPoint(x: leadingInset + buttonSize.width + spacing, y: y))
        zoomButton.setFrameOrigin(NSPoint(x: leadingInset + (buttonSize.width + spacing) * 2, y: y))
    }

    private func fastImageAspectRatio(for url: URL) -> CGFloat? {
        if url.pathExtension.lowercased() == "svg",
           let svgAspect = fastSVGAspectRatio(for: url) {
            return svgAspect
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0,
              height > 0 else {
            return nil
        }
        return width / height
    }

    private func fastSVGAspectRatio(for url: URL) -> CGFloat? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        if let viewBoxRange = text.range(of: #"viewBox\s*=\s*"([^"]+)""#, options: .regularExpression) {
            let raw = String(text[viewBoxRange])
            let value = raw
                .replacingOccurrences(of: #"viewBox\s*=\s*""#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "\"", with: "")
            let parts = value.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
            if parts.count == 4, parts[2] > 0, parts[3] > 0 {
                return CGFloat(parts[2] / parts[3])
            }
        }

        func dimension(_ attribute: String) -> CGFloat? {
            guard let range = text.range(of: #"\#(attribute)\s*=\s*"([^"]+)""#, options: .regularExpression) else {
                return nil
            }
            let raw = String(text[range])
            let value = raw
                .replacingOccurrences(of: #"\#(attribute)\s*=\s*""#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let numeric = value.replacingOccurrences(of: #"[^0-9.\-]+"#, with: "", options: .regularExpression)
            guard let parsed = Double(numeric), parsed > 0 else { return nil }
            return CGFloat(parsed)
        }

        if let width = dimension("width"), let height = dimension("height"), height > 0 {
            return width / height
        }

        return nil
    }

    // MARK: - Actions

    @objc private func openSettings() {
        if let w = settingsWindow, w.isVisible { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: SettingsView())
        w.title = "QuickPeek 设置"
        w.minSize = NSSize(width: 500, height: 470)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = w
    }

    @objc private func reinstallShortcutMonitor() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if trusted {
            setupEventTap()
            refreshSelectionContext()
        }
        updateMenu()
    }

    @objc private func quit() {
        stopEventTapHealthMonitoring()
        removeEventTap()
        removeArrowKeyMonitors()
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        NSApp.terminate(nil)
    }
}

// MARK: - CGEvent Tap C Callback (free function, not a method)
// This runs on the main RunLoop thread. It must be fast and not block.

private func spaceKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    // Re-enable if system disabled the tap
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = TapSharedState.shared.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passRetained(event)
    }

    guard type == .keyDown else {
        return Unmanaged.passRetained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

    // Only intercept bare Space key (keyCode 49), no modifiers
    guard keyCode == Int64(kVK_Space) else {
        return Unmanaged.passRetained(event)
    }

    // Check no modifier keys are held
    let flags = event.flags
    let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
    guard flags.intersection(modifierMask).isEmpty else {
        return Unmanaged.passRetained(event)
    }

    // Check if Finder is frontmost
    let frontApp = NSWorkspace.shared.frontmostApplication
    let isFinderFront = frontApp?.bundleIdentifier == "com.apple.finder"
    let isVisible = TapSharedState.shared.previewVisible
    let isPinned = TapSharedState.shared.previewPinned
    let isQuickPeekFront = frontApp?.bundleIdentifier == Bundle.main.bundleIdentifier

    if TapSharedState.shared.timelineEditing {
        return Unmanaged.passRetained(event)
    }

    // Only intercept when QuickPeek itself is frontmost with a visible preview,
    // or Finder is frontmost. Finder interception is intentionally aggressive
    // so system Quick Look doesn't occasionally slip through during selection lag.
    guard ((isVisible && !isPinned && isQuickPeekFront) || isFinderFront) else {
        return Unmanaged.passRetained(event)
    }

    // If Finder is front, check whether the user is currently editing text
    // (e.g. renaming a file). In that case, let the space key through.
    if isFinderFront && !isVisible {
        if let finderApp = frontApp {
            let appRef = AXUIElementCreateApplication(finderApp.processIdentifier)
            var focusedRaw: AnyObject?
            let focusErr = AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focusedRaw)
            if focusErr == .success, let focused = focusedRaw {
                let focusedElement = focused as! AXUIElement
                var roleRaw: AnyObject?
                AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &roleRaw)
                if let role = roleRaw as? String,
                   role == kAXTextFieldRole || role == kAXTextAreaRole {
                    // User is typing in a text field (renaming), don't intercept
                    return Unmanaged.passRetained(event)
                }
            }
        }

    }

    // Dispatch to main actor to handle the preview toggle
    // We suppress the event immediately (return nil) to prevent system Quick Look
    guard let refcon = refcon else {
        return Unmanaged.passRetained(event)
    }

    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        delegate.handleSpaceDown()
    }

    // Return nil to suppress the space key — prevents system Quick Look
    return nil
}
