import SwiftUI
import AppKit
import CleanerCore

@MainActor
public final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    nonisolated(unsafe) private var keyMonitor: Any?
    private var completedThroughButton = false

    public let model: WelcomeOnboardingModel
    private let userDefaults: UserDefaults

    public init(
        userDefaults: UserDefaults = .standard,
        permissionChecker: any FullDiskAccessChecking = SystemFullDiskAccessChecker(),
        initialPermissionStatus: FullDiskAccessStatus? = nil,
        observesApplicationActivation: Bool = true,
        notificationCenter: NotificationCenter = .default,
        openURLHandler: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        onDismissedWithoutCompletion: (@MainActor (FullDiskAccessStatus) -> Void)? = nil,
        onCompleted: (@MainActor (FullDiskAccessStatus) -> Void)? = nil,
        onPermissionStatusChanged: (@MainActor (FullDiskAccessStatus) -> Void)? = nil
    ) {
        self.userDefaults = userDefaults
        weak var weakSelf: WelcomeWindowController?
        self.model = WelcomeOnboardingModel(
            isFirstLaunch: WelcomeOnboardingPolicy.shouldShowOnLaunch(userDefaults: userDefaults),
            userDefaults: userDefaults,
            permissionChecker: permissionChecker,
            initialPermissionStatus: initialPermissionStatus,
            isPresented: false,
            observesApplicationActivation: observesApplicationActivation,
            notificationCenter: notificationCenter,
            openURLHandler: openURLHandler,
            onCloseWindow: {
                weakSelf?.closeWindowProgrammatically()
            },
            onDismissedWithoutCompletion: onDismissedWithoutCompletion,
            onCompleted: { status in
                weakSelf?.completedThroughButton = true
                onCompleted?(status)
            },
            onPermissionStatusChanged: onPermissionStatusChanged
        )
        super.init()
        weakSelf = self
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    public var attachedWindow: NSWindow? {
        window
    }

    public var isVisible: Bool {
        window?.isVisible == true
    }

    public func showIfNeededOnLaunch() {
        guard WelcomeOnboardingPolicy.shouldShowOnLaunch(userDefaults: userDefaults) else {
            return
        }
        show(isFirstLaunch: true)
    }

    public func show(isFirstLaunch: Bool = false) {
        completedThroughButton = false
        model.isPresented = true
        model.resetForPresentation(isFirstLaunch: isFirstLaunch)

        let targetWindow = ensureWindow()
        targetWindow.center()
        targetWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitorIfNeeded()
    }

    public func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let window, event.window === window else {
            return false
        }

        switch event.keyCode {
        case 53: // Escape
            completedThroughButton = true
            model.dismissViaEscape()
            return true
        case 125, 124: // Down Arrow, Right Arrow
            if let next = model.currentStep.next {
                let policy = WelcomeTransitionPolicy.resolve(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                let animation: Animation = policy.reduceMotion
                    ? .easeInOut(duration: policy.duration)
                    : .easeOut(duration: policy.duration)
                withAnimation(animation) {
                    model.selectStep(next)
                }
            }
            return true
        case 126, 123: // Up Arrow, Left Arrow
            if let prev = model.currentStep.previous {
                let policy = WelcomeTransitionPolicy.resolve(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                let animation: Animation = policy.reduceMotion
                    ? .easeInOut(duration: policy.duration)
                    : .easeOut(duration: policy.duration)
                withAnimation(animation) {
                    model.selectStep(prev)
                }
            }
            return true
        case 36, 76: // Return, Keypad Enter
            switch model.focusedControl {
            case .openSettingsButton:
                model.openFullDiskAccessSettings()
                return true
            case .refreshPermissionButton:
                model.refreshPermissionStatus()
                return true
            case .backButton:
                if let prev = model.currentStep.previous {
                    let policy = WelcomeTransitionPolicy.resolve(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                    let animation: Animation = policy.reduceMotion
                        ? .easeInOut(duration: policy.duration)
                        : .easeOut(duration: policy.duration)
                    withAnimation(animation) {
                        model.selectStep(prev)
                    }
                }
                return true
            case .step, .primaryButton, .none:
                let policy = WelcomeTransitionPolicy.resolve(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                let animation: Animation = policy.reduceMotion
                    ? .easeInOut(duration: policy.duration)
                    : .easeOut(duration: policy.duration)
                withAnimation(animation) {
                    model.advanceOrComplete()
                }
                return true
            }
        default:
            return false
        }
    }

    private func ensureWindow() -> NSWindow {
        if let existing = window {
            return existing
        }

        let size = WelcomeOnboardingPolicy.windowSize
        let created = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        created.title = "Welcome to CleanerMac"
        created.titleVisibility = .hidden
        created.titlebarAppearsTransparent = true
        created.isMovableByWindowBackground = true
        created.isReleasedWhenClosed = false
        created.backgroundColor = .windowBackgroundColor
        created.isOpaque = true
        created.contentMinSize = size
        created.contentMaxSize = size
        created.autorecalculatesKeyViewLoop = true
        created.identifier = WelcomeOnboardingPolicy.windowIdentifier
        created.delegate = self

        let hostingView = NSHostingView(rootView: WelcomeOnboardingView(model: model))
        hostingView.frame = NSRect(origin: .zero, size: size)
        created.contentView = hostingView
        created.setContentSize(size)

        window = created
        return created
    }

    private func closeWindowProgrammatically() {
        removeKeyMonitor()
        model.isPresented = false
        window?.close()
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.handleKeyEvent(event) {
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    public func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        model.isPresented = false
        if !completedThroughButton {
            model.handleWindowClosedWithoutCompletion()
        }
        completedThroughButton = false
    }
}
