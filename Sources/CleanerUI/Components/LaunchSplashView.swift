import SwiftUI
import AppKit
import CleanerCore

public struct LaunchSplashPolicy: Equatable, Sendable {
    public let reduceMotion: Bool
    public let entranceDuration: TimeInterval
    public let entranceScale: CGFloat
    public let usesSpringEntrance: Bool
    public let usesSymbolReplace: Bool
    public let dismissDelay: TimeInterval
    public let dismissDuration: TimeInterval

    public var totalDuration: TimeInterval {
        dismissDelay + dismissDuration
    }

    public static func resolve(reduceMotion: Bool) -> LaunchSplashPolicy {
        if reduceMotion {
            return LaunchSplashPolicy(
                reduceMotion: true,
                entranceDuration: 0.18,
                entranceScale: 1.0,
                usesSpringEntrance: false,
                usesSymbolReplace: false,
                dismissDelay: 0.56,
                dismissDuration: 0.26
            )
        } else {
            return LaunchSplashPolicy(
                reduceMotion: false,
                entranceDuration: 0.26,
                entranceScale: 0.96,
                usesSpringEntrance: true,
                usesSymbolReplace: false,
                dismissDelay: 0.62,
                dismissDuration: 0.26
            )
        }
    }
}

public struct LaunchSplashView: View {
    @Binding private var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var isEntered = false
    @State private var overlayOpacity = 1.0

    private let reduceMotionOverride: Bool?

    public init(isPresented: Binding<Bool>, reduceMotionOverride: Bool? = nil) {
        self._isPresented = isPresented
        self.reduceMotionOverride = reduceMotionOverride
    }

    private var effectiveReduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }

    private var policy: LaunchSplashPolicy {
        LaunchSplashPolicy.resolve(reduceMotion: effectiveReduceMotion)
    }

    public var body: some View {
        let activePolicy = policy

        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: CleanerSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(CleanerColors.safe)
                    .frame(width: 48, height: 48)

                VStack(spacing: CleanerSpacing.xxs) {
                    Text("CleanerMac")
                        .font(CleanerTypography.displayHero())
                        .foregroundStyle(.primary)

                    Text("Local Disk Cleaner")
                        .font(CleanerTypography.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .opacity(isEntered ? 1 : 0)
            .scaleEffect(activePolicy.usesSpringEntrance ? (isEntered ? 1.0 : activePolicy.entranceScale) : 1.0)
        }
        .background(SplashFocusGuard())
        .opacity(overlayOpacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: activePolicy.reduceMotion) {
            await runLaunchSequence(with: activePolicy)
        }
    }

    @MainActor
    private func runLaunchSequence(with activePolicy: LaunchSplashPolicy) async {
        guard isPresented else { return }

        let start = ContinuousClock.now
        let entranceAnimation: Animation = activePolicy.usesSpringEntrance
            ? .spring(duration: activePolicy.entranceDuration, bounce: 0.14)
            : .easeInOut(duration: activePolicy.entranceDuration)

        withAnimation(entranceAnimation) {
            isEntered = true
        }

        let dismissDeadline = start.advanced(by: .seconds(activePolicy.dismissDelay))
        try? await Task.sleep(until: dismissDeadline)
        guard !Task.isCancelled, isPresented else { return }

        let exitAnimation: Animation = activePolicy.reduceMotion
            ? .easeInOut(duration: activePolicy.dismissDuration)
            : .easeOut(duration: activePolicy.dismissDuration)

        withAnimation(exitAnimation, completionCriteria: .removed) {
            overlayOpacity = 0
        } completion: {
            isPresented = false
        }
    }
}

private struct SplashFocusGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> FocusGuardNSView {
        FocusGuardNSView()
    }

    func updateNSView(_ nsView: FocusGuardNSView, context: Context) {}

    static func dismantleNSView(_ nsView: FocusGuardNSView, coordinator: ()) {
        nsView.stopObserving()
    }

    @MainActor
    final class FocusGuardNSView: NSView {
        nonisolated(unsafe) private var observation: NSKeyValueObservation?
        private var isActive = true

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation?.invalidate()
            observation = nil
            guard isActive, let window else { return }

            if let responder = window.firstResponder, responder !== window {
                let eventType = NSApp.currentEvent?.type
                let isUserInitiated = eventType == .keyDown
                    || eventType == .leftMouseDown
                    || eventType == .rightMouseDown
                    || eventType == .otherMouseDown
                if !isUserInitiated {
                    Task { @MainActor [weak self, weak window] in
                        guard let self, self.isActive, let window else { return }
                        if window.firstResponder !== window {
                            window.makeFirstResponder(nil)
                        }
                    }
                } else {
                    isActive = false
                }
            }

            observation = window.observe(\.firstResponder, options: [.new]) { [weak self, weak window] _, _ in
                MainActor.assumeIsolated {
                    guard let self, self.isActive, let window else { return }
                    guard let responder = window.firstResponder, responder !== window else { return }

                    let eventType = NSApp.currentEvent?.type
                    let isUserInitiated = eventType == .keyDown
                        || eventType == .leftMouseDown
                        || eventType == .rightMouseDown
                        || eventType == .otherMouseDown
                    if isUserInitiated {
                        self.stopObserving()
                        return
                    }

                    Task { @MainActor [weak self, weak window] in
                        guard let self, self.isActive, let window else { return }
                        if window.firstResponder !== window {
                            window.makeFirstResponder(nil)
                        }
                    }
                }
            }
        }

        func stopObserving() {
            isActive = false
            observation?.invalidate()
            observation = nil
        }

        deinit {
            observation?.invalidate()
        }
    }
}

